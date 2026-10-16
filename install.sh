#!/bin/bash

# Check if the user has root access
if [ "$EUID" -ne 0 ]; then
  echo $'\e[32mPlease run with root privileges.\e[0m'
  exit 1
fi

# If launched via process substitution (bash <(curl ...)), install self to disk
# so that the interactive menu can re-invoke itself reliably.
if [ ! -f "$0" ]; then
    mkdir -p /etc/gost
    if command -v curl >/dev/null 2>&1; then
        curl -Ls https://raw.githubusercontent.com/Aknuun/Gost-ip6/main/install.sh -o /etc/gost/install.sh
    else
        wget -qO /etc/gost/install.sh https://raw.githubusercontent.com/Aknuun/Gost-ip6/main/install.sh
    fi
    chmod +x /etc/gost/install.sh
    exec bash /etc/gost/install.sh
fi

# Global paths
WATCHDOG_BIN=/usr/local/bin/gost-watchdog.sh
WATCHDOG_SVC=/etc/systemd/system/gost-watchdog.service
WATCHDOG_TIMER=/etc/systemd/system/gost-watchdog.timer

#####################################################################
# Helpers
#####################################################################

# Create a swap file sized according to the server's RAM / free disk
ensure_swap() {
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        echo $'\e[32mSwap already active. Skipping swap creation.\e[0m'
        return 0
    fi

    local ram_mb swap_mb free_mb
    ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)

    if   (( ram_mb < 1024 )); then swap_mb=2048
    elif (( ram_mb < 2048 )); then swap_mb=2048
    elif (( ram_mb < 4096 )); then swap_mb=2048
    elif (( ram_mb < 8192 )); then swap_mb=1024
    else                           swap_mb=1024
    fi

    free_mb=$(df -m / | awk 'NR==2{print $4}')
    if (( free_mb < swap_mb + 1024 )); then
        swap_mb=$(( free_mb - 1024 ))
        if (( swap_mb < 512 )); then
            echo $'\e[33mNot enough free disk for a swap file. Skipping.\e[0m'
            return 0
        fi
    fi

    echo $'\e[32mCreating a '"$swap_mb"$'MB swap file (RAM: '"$ram_mb"'MB)...\e[0m'

    if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null 2>&1

    echo $'\e[32mSwap enabled successfully.\e[0m'
}

# Network / kernel tuning for many concurrent connections
apply_sysctl() {
    echo $'\e[32mApplying network & system tuning...\e[0m'
    modprobe nf_conntrack 2>/dev/null

    cat > /etc/sysctl.d/99-gost-tuning.conf <<'EOF'
# Gost-ip6 optimized tuning
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
fs.file-max = 1048576
vm.swappiness = 10
EOF

    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        cat >> /etc/sysctl.d/99-gost-tuning.conf <<'EOF'
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
EOF
    fi

    sysctl --system >/dev/null 2>&1
    echo $'\e[32mTuning applied.\e[0m'
}

# Cap journald disk usage (gost logs every connection -> huge journals)
cap_journald() {
    echo $'\e[32mCapping journald size...\e[0m'
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-gost.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
    systemctl restart systemd-journald 2>/dev/null
    journalctl --vacuum-size=200M >/dev/null 2>&1
    echo $'\e[32mjournald capped at 200M.\e[0m'
}

# Write a hardened gost systemd unit (auto-restart + OOM protection)
write_gost_unit() {
    local unitname="$1"
    local exec_line="$2"
    cat > "/usr/lib/systemd/system/${unitname}.service" <<EOL
[Unit]
Description=GO Simple Tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
Restart=always
RestartSec=5
OOMScoreAdjust=-1000
LimitNOFILE=1048576
TasksMax=infinity
${exec_line}

[Install]
WantedBy=multi-user.target
EOL
}

# Install the auto-heal watchdog (restart -> reboot -> give up)
install_watchdog() {
    echo $'\e[32mInstalling Auto-Heal watchdog...\e[0m'

    cat > "$WATCHDOG_BIN" <<'WATCHEOF'
#!/bin/bash
# Gost auto-heal watchdog: restart -> reboot -> give up
STATE_DIR=/var/lib/gost-watchdog
STATE_FILE="$STATE_DIR/state"
LOG_FILE=/var/log/gost-watchdog.log
MAX_RESTARTS=3
GRACE_AFTER_REBOOT=300
PROBE_TIMEOUT=3

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
if [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then : > "$LOG_FILE"; fi

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

FAILS=0; RESTARTS=0; REBOOTED=0; LAST_REBOOT=0
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

save_state() { printf 'FAILS=%s\nRESTARTS=%s\nREBOOTED=%s\nLAST_REBOOT=%s\n' "$FAILS" "$RESTARTS" "$REBOOTED" "$LAST_REBOOT" > "$STATE_FILE"; }
reset_state() { FAILS=0; RESTARTS=0; REBOOTED=0; LAST_REBOOT=0; save_state; }

services_list() {
  { ls /usr/lib/systemd/system/gost_*.service 2>/dev/null
    ls /etc/systemd/system/gost_*.service 2>/dev/null; } | grep -v 'multi-user.target' | sort -u
}

health_ok() {
  local files; files=$(services_list)
  [ -z "$files" ] && return 0
  local f u spec proto port
  for f in $files; do
    u=$(basename "$f")
    systemctl is-active --quiet "$u" || return 1
  done
  for f in $files; do
    while read -r spec; do
      [ -z "$spec" ] && continue
      proto="${spec%%://*}"; port="${spec##*:}"
      case "$proto" in
        tcp|grpc)
          if ! timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            return 1
          fi
          ;;
      esac
    done < <(grep -oP '(tcp|grpc)://:[0-9]+(?=/\[)' "$f" 2>/dev/null | head -3)
  done
  return 0
}

if health_ok; then
  if [ "$REBOOTED" = "1" ] || [ "$FAILS" != "0" ] || [ "$RESTARTS" != "0" ]; then
    log "healthy; resetting state"
    reset_state
  fi
  exit 0
fi

now=$(date +%s)
FAILS=$((FAILS+1))

# Already rebooted once for this failure -> do nothing more
if [ "$REBOOTED" = "1" ]; then
  if [ $(( now - LAST_REBOOT )) -lt "$GRACE_AFTER_REBOOT" ]; then
    log "unhealthy (fails=$FAILS) but inside post-reboot grace window; waiting"
    save_state; exit 0
  fi
  log "still unhealthy after reboot; giving up (problem likely elsewhere). No further action."
  save_state; exit 0
fi

# Stage 1: restart the tunnel
if [ "$RESTARTS" -lt "$MAX_RESTARTS" ]; then
  log "unhealthy (fails=$FAILS); restarting gost services (attempt $((RESTARTS+1))/$MAX_RESTARTS)"
  systemctl daemon-reload
  systemctl restart gost_*.service 2>/dev/null
  RESTARTS=$((RESTARTS+1)); save_state
  sleep 10
  if health_ok; then log "recovered after restart"; reset_state; exit 0; fi
  exit 0
fi

# Stage 2: restarts exhausted -> reboot once
log "restart attempts exhausted; rebooting server once"
REBOOTED=1; RESTARTS=0; FAILS=0; LAST_REBOOT=$now; save_state
sync
systemctl reboot
WATCHEOF

    chmod +x "$WATCHDOG_BIN"

    cat > "$WATCHDOG_SVC" <<'EOF'
[Unit]
Description=Gost tunnel watchdog (auto-heal)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gost-watchdog.sh
EOF

    cat > "$WATCHDOG_TIMER" <<'EOF'
[Unit]
Description=Run gost watchdog periodically

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-watchdog.timer >/dev/null 2>&1
    echo $'\e[32mAuto-Heal watchdog installed & enabled (checks every 60s).\e[0m'
}

remove_watchdog() {
    systemctl disable --now gost-watchdog.timer >/dev/null 2>&1
    rm -f "$WATCHDOG_BIN" "$WATCHDOG_SVC" "$WATCHDOG_TIMER"
    systemctl daemon-reload
    echo $'\e[32mAuto-Heal watchdog removed.\e[0m'
}

# Apply the full optimization bundle
apply_optimizations() {
    ensure_swap
    apply_sysctl
    cap_journald
}

#####################################################################
# Banner + menu
#####################################################################

echo $'\e[35m'"  ___|              |        _ _|  _ \   /    
 |      _ \    __|  __|        |  |   |  _ \  
 |   | (   | \__ \  |          |  ___/  (   | 
\____|\___/  ____/ \__|      ___|_|    \___/  
                                              "$'\e[0m'

echo -e "\e[36mCreated By Masoud Gb Special Thanks Hamid Router\e[0m"
echo -e "\e[36mOptimized Fork by Aknuun (Auto Swap + Tuning + Auto-Heal)\e[0m"
echo $'\e[35m'"Gost Ip6 Script v2.3.0-opt"$'\e[0m'

options=($'\e[36m1. \e[0mGost Tunnel By IP4'
         $'\e[36m2. \e[0mGost Tunnel By IP6'
         $'\e[36m3. \e[0mGost Status'
         $'\e[36m4. \e[0mUpdate Script'
         $'\e[36m5. \e[0mAdd New IP'
         $'\e[36m6. \e[0mChange Gost Version'
         $'\e[36m7. \e[0mAuto Restart Gost'
         $'\e[36m8. \e[0mAuto Clear Cache'
         $'\e[36m9. \e[0mInstall BBR'
         $'\e[36m10. \e[0mUninstall'
         $'\e[36m11. \e[0mApply Optimizations (Swap + Tuning)'
         $'\e[36m12. \e[0mInstall Auto-Heal Watchdog'
         $'\e[36m13. \e[0mRemove Auto-Heal Watchdog'
         $'\e[36m14. \e[0mExit')

printf "\e[32mPlease Choice Your Options:\e[0m\n"
printf "%s\n" "${options[@]}"

read -p $'\e[97mYour choice: \e[0m' choice

# If option 1 or 2 is selected
if [ "$choice" -eq 1 ] || [ "$choice" -eq 2 ]; then
    if [ "$choice" -eq 1 ]; then
        read -p $'\e[97mPlease enter the destination (Kharej) IPv4: \e[0m' destination_ip
    elif [ "$choice" -eq 2 ]; then
        read -p $'\e[97mPlease enter the destination (Kharej) IPv6: \e[0m' destination_ip
    fi

    read -p $'\e[32mPlease choose one of the options below:\n\e[0m\e[36m1. \e[0mEnter "Manually" Ports\n\e[36m2. \e[0mEnter "Range" Ports\e[32m\nYour choice: \e[0m' port_option

if [ "$port_option" -eq 1 ]; then
    read -p $'\e[36mPlease enter the desired ports (separated by commas): \e[0m' ports
elif [ "$port_option" -eq 2 ]; then
    read -p $'\e[36mPlease enter the port range (e.g., 54,65000): \e[0m' port_range

    IFS=',' read -ra port_array <<< "$port_range"

    if [ "${port_array[0]}" -lt 54 -o "${port_array[1]}" -gt 65000 ]; then
        echo $'\e[33mInvalid port range. Please enter a valid range starting from 54 and up to 65000.\e[0m'
        exit
    fi

    ports=$(seq -s, "${port_array[0]}" "${port_array[1]}")
else
    echo $'\e[31mInvalid option. Exiting...\e[0m'
    exit
fi

    read -p $'\e[32mSelect the protocol:\n\e[0m\e[36m1. \e[0mBy "Tcp" Protocol \n\e[36m2. \e[0mBy "Udp" Protocol \n\e[36m3. \e[0mBy "Grpc" Protocol \e[32m\nYour choice: \e[0m' protocol_option

if [ "$protocol_option" -eq 1 ]; then
    protocol="tcp"
elif [ "$protocol_option" -eq 2 ]; then
    protocol="udp"
elif [ "$protocol_option" -eq 3 ]; then
    protocol="grpc"
else
    echo $'\e[31mInvalid protocol option. Exiting...\e[0m'
    exit
fi

    echo $'\e[32mYou chose option\e[0m' $choice
    echo $'\e[97mDestination IP:\e[0m' $destination_ip
    echo $'\e[97mPorts:\e[0m' $ports
    echo $'\e[97mProtocol:\e[0m' $protocol

    echo $'\e[32mUpdating system packages, please wait...\e[0m'
    sysctl net.ipv4.ip_local_port_range="1024 65535"
echo "sysctl net.ipv4.ip_local_port_range=\"1024 65535\"" >> /etc/rc.local

cat <<EOL > /etc/systemd/system/sysctl-custom.service
[Unit]
Description=Custom sysctl settings

[Service]
ExecStart=/sbin/sysctl net.ipv4.ip_local_port_range="1024 65535"

[Install]
WantedBy=multi-user.target
EOL
systemctl enable sysctl-custom

    apt update && apt install wget nano -y && \
        echo 'alias gost="bash /etc/gost/install.sh"' >> ~/.bashrc
        source ~/.bashrc
        echo $'\e[32mSymbolic link created: /usr/local/bin/gost\e[0m'
    echo $'\e[32mSystem update completed.\e[0m'

    echo $'\e[32mChoose Gost version:\e[0m'
    echo $'\e[36m1. \e[0mGost version 2.11.5 (official)'
    echo $'\e[36m2. \e[0mGost version 3.0.0 (latest)'

    read -p $'\e[97mYour choice: \e[0m' gost_version_choice

if [ "$gost_version_choice" -eq 1 ]; then
    echo $'\e[32mInstalling Gost version 2.11.5, please wait...\e[0m' && \
    wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz && \
    echo $'\e[32mGost downloaded successfully.\e[0m' && \
    gunzip gost-linux-amd64-2.11.5.gz && \
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost && \
    chmod +x /usr/local/bin/gost && \
    echo $'\e[32mGost installed successfully.\e[0m'
else
    if [ "$gost_version_choice" -eq 2 ]; then
        echo $'\e[32mInstalling the latest Gost version 3.x, please wait...\e[0m'
        download_url="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz"
        echo $'\e[32mDownloading Gost 3.0.0...\e[0m'
        wget -O /tmp/gost.tar.gz "$download_url"
        if [ ! -s /tmp/gost.tar.gz ]; then
            echo $'\e[31mError: Download failed or file empty.\e[0m'
            exit 1
        fi
        tar -xvzf /tmp/gost.tar.gz -C /usr/local/bin/
        chmod +x /usr/local/bin/gost
        echo $'\e[32mGost 3.0.0 installed successfully.\e[0m'
    else
        echo $'\e[31mInvalid choice. Exiting...\e[0m'
        exit
    fi
fi

    IFS=',' read -ra port_array <<< "$ports"
    port_count=${#port_array[@]}
    max_ports_per_file=12000
    file_count=$(( (port_count + max_ports_per_file - 1) / max_ports_per_file ))

    for ((file_index = 0; file_index < file_count; file_index++)); do
        exec_start_command="ExecStart=/usr/local/bin/gost"
        for ((i = file_index * max_ports_per_file; i < (file_index + 1) * max_ports_per_file && i < port_count; i++)); do
            port="${port_array[i]}"
            exec_start_command+=" -L=$protocol://:$port/[$destination_ip]:$port"
        done

        write_gost_unit "gost_$file_index" "$exec_start_command"
    done

    systemctl daemon-reload
    for ((file_index = 0; file_index < file_count; file_index++)); do
        systemctl enable "gost_$file_index.service" >/dev/null 2>&1
        systemctl restart "gost_$file_index.service"
    done

    echo $'\e[32mGost configuration applied successfully.\e[0m'

    # --- Automatic optimizations on install ---
    echo $'\e[32mRunning automatic optimizations...\e[0m'
    apply_optimizations
    install_watchdog

    echo $'\e[32mAll done. Tunnel is up with auto-heal enabled.\e[0m'

    bash "$0"

# If option 3 is selected
elif [ "$choice" -eq 3 ]; then
    if command -v gost &>/dev/null; then
        echo $'\e[32mGost is installed. Checking configuration and status...\e[0m'
        systemctl list-unit-files | grep -q "gost_"
        if [ $? -eq 0 ]; then
            echo $'\e[32mGost is configured and active.\e[0m'
            for service_file in /usr/lib/systemd/system/gost_*.service; do
                service_info=$(awk -F'[-=:/\\[\\]]+' '/ExecStart=/ {print $14,$15,$22,$20,$23}' "$service_file")
                read -a info_array <<< "$service_info"
                echo -e "\e[97mIP:\e[0m ${info_array[0]} \e[97mPort:\e[0m ${info_array[1]},... \e[97mProtocol:\e[0m ${info_array[2]}"
            done
        else
            echo $'\e[33mGost is installed, but not configured or active.\e[0m'
        fi
    else
        echo $'\e[33mGost Tunnel is not installed. \e[0m'
    fi

    read -n 1 -s -r -p $'\e[36m0. \e[0mBack to menu: \e[0m' choice
    if [ "$choice" -eq 0 ]; then
        bash "$0"
    fi

# If option 4 is selected
elif [ "$choice" -eq 4 ]; then
    read -p $'\e[32mDo you want to update Gost script? (y/n): \e[0m' update_choice
    if [ "$update_choice" == "y" ]; then
        echo $'\e[32mUpdating Gost script, please wait...\e[0m'
        mkdir -p /etc/gost
        wget -O /etc/gost/install.sh https://raw.githubusercontent.com/Aknuun/Gost-ip6/main/install.sh
        chmod +x /etc/gost/install.sh
        echo $'\e[32mUpdate completed.\e[0m'
    else
        echo $'\e[32mUpdate canceled.\e[0m'
    fi
    bash "$0"

# If option 5 is selected
elif [ "$choice" -eq 5 ]; then
    read -p $'\e[97mPlease enter the new destination (Kharej) IP 4 or 6: \e[0m' destination_ip
    read -p $'\e[36mPlease enter the new port (separated by commas): \e[0m' port
    read -p $'\e[32mSelect the protocol:\n\e[0m\e[36m1. \e[0mBy Tcp Protocol \n\e[36m2. \e[0mBy Grpc Protocol \e[32m\nYour choice: \e[0m' protocol_option

    if [ "$protocol_option" -eq 1 ]; then
        protocol="tcp"
    elif [ "$protocol_option" -eq 2 ]; then
        protocol="grpc"
    else
        echo $'\e[31mInvalid protocol option. Exiting...\e[0m'
        exit
    fi

    echo $'\e[32mYou chose option\e[0m' $choice
    echo $'\e[97mDestination IP:\e[0m' $destination_ip
    echo $'\e[97mPort(s):\e[0m' $port
    echo $'\e[97mProtocol:\e[0m' $protocol

    IFS=',' read -ra port_array <<< "$port"
    port_count=${#port_array[@]}
    max_ports_per_file=12000
    file_count=$(( (port_count + max_ports_per_file - 1) / max_ports_per_file ))

    for ((file_index = 0; file_index < file_count; file_index++)); do
        exec_start_command="ExecStart=/usr/local/bin/gost"
        for ((i = file_index * max_ports_per_file; i < (file_index + 1) * max_ports_per_file && i < port_count; i++)); do
            port="${port_array[i]}"
            exec_start_command+=" -L=$protocol://:$port/[$destination_ip]:$port"
        done
        write_gost_unit "gost_$destination_ip" "$exec_start_command"
    done

    systemctl daemon-reload
    systemctl enable "gost_$destination_ip.service" >/dev/null 2>&1
    systemctl restart "gost_$destination_ip.service"
    echo $'\e[32mGost configuration applied successfully.\e[0m'
    bash "$0"

# If option 6 is selected
elif [ "$choice" -eq 6 ]; then
    echo $'\e[32mChoose Gost version:\e[0m'
    echo $'\e[36m1. \e[0mGost version 2.11.5 (official)'
    echo $'\e[36m2. \e[0mGost version 3.x (latest)'

    read -p $'\e[97mYour choice: \e[0m' gost_version_choice

    case "$gost_version_choice" in
        1)
            echo $'\e[32mInstalling Gost version 2.11.5, please wait...\e[0m' && \
            wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz && \
            gunzip gost-linux-amd64-2.11.5.gz && \
            mv gost-linux-amd64-2.11.5 /usr/local/bin/gost && \
            chmod +x /usr/local/bin/gost && \
            echo $'\e[32mGost installed successfully.\e[0m'
            ;;
        2)
            echo $'\e[32mInstalling the latest Gost version 3.x, please wait...\e[0m' && \
            download_url=$(curl -s https://api.github.com/repos/go-gost/gost/releases | \
                           grep -oP '"browser_download_url": "\K(.*?linux.*?\.tar\.gz)(?=")' | \
                           grep -E 'v3\.' | head -n 1)
            if [ -z "$download_url" ]; then
                echo $'\e[31mError: Could not find the download URL for the latest 3.x Gost version.\e[0m'
                exit 1
            fi
            wget -O /tmp/gost.tar.gz "$download_url"
            if [ ! -s /tmp/gost.tar.gz ]; then
                echo $'\e[31mError: Download failed or file empty.\e[0m'
                exit 1
            fi
            tar -xvzf /tmp/gost.tar.gz -C /usr/local/bin/ && \
            chmod +x /usr/local/bin/gost && \
            echo $'\e[32mGost 3.x installed successfully.\e[0m'
            ;;
        *)
            echo $'\e[31mInvalid choice. Exiting...\e[0m'
            exit
            ;;
    esac
    bash "$0"

# If option 7 is selected
elif [ "$choice" -eq 7 ]; then
    echo $'\e[32mChoose Auto Restart option:\e[0m'
    echo $'\e[36m1. \e[0mEnable Auto Restart'
    echo $'\e[36m2. \e[0mDisable Auto Restart'

    read -p $'\e[97mYour choice: \e[0m' auto_restart_option

    case "$auto_restart_option" in
        1)
            echo $'\e[32mAuto Restart Enabled.\e[0m'
            command -v at >/dev/null 2>&1 && { at -l | awk '{print $1}' | xargs -I {} atrm {}; }
            read -p $'\e[97mEnter the restart time in hours: \e[0m' restart_time_hours
            echo -e "#!/bin/bash\n\nsystemctl daemon-reload\nsystemctl restart gost_*.service" | tee /usr/bin/auto_restart_cronjob.sh > /dev/null
            chmod +x /usr/bin/auto_restart_cronjob.sh
            crontab -l 2>/dev/null | grep -v '/usr/bin/auto_restart_cronjob.sh' | crontab -
            (crontab -l 2>/dev/null ; echo "0 */$restart_time_hours * * * /usr/bin/auto_restart_cronjob.sh") | crontab -
            echo $'\e[32mAuto Restart scheduled successfully.\e[0m'
            ;;
        2)
            echo $'\e[32mAuto Restart Disabled.\e[0m'
            rm -f /usr/bin/auto_restart_cronjob.sh
            crontab -l 2>/dev/null | grep -v '/usr/bin/auto_restart_cronjob.sh' | crontab -
            echo $'\e[32mAuto Restart disabled successfully.\e[0m'
            ;;
        *)
            echo $'\e[31mInvalid choice. Exiting...\e[0m'
            exit
            ;;
    esac
    bash "$0"

# If option 8 is selected
elif [ "$choice" -eq 8 ]; then
    echo $'\e[32mChoose Auto Clear Cache option:\e[0m'
    echo $'\e[36m1. \e[0mEnable Auto Clear Cache'
    echo $'\e[36m2. \e[0mDisable Auto Clear Cache'

    read -p $'\e[97mYour choice: \e[0m' auto_clear_cache_option

    case "$auto_clear_cache_option" in
        1)
            echo $'\e[32mAuto Clear Cache Enabled.\e[0m'
            read -p $'\e[97mEnter the interval in days (e.g., 1 for daily, 7 for weekly): \e[0m' interval_days
            cron_interval="0 0 */$interval_days * *"
            (crontab -l 2>/dev/null; echo "$cron_interval sync; echo 1 > /proc/sys/vm/drop_caches && sync; echo 2 > /proc/sys/vm/drop_caches && sync; echo 3 > /proc/sys/vm/drop_caches") | crontab -
            echo $'\e[32mAuto Clear Cache scheduled successfully.\e[0m'
            ;;
        2)
            echo $'\e[32mAuto Clear Cache Disabled.\e[0m'
            crontab -l 2>/dev/null | grep -v "drop_caches" | crontab -
            echo $'\e[32mAuto Clear Cache disabled successfully.\e[0m'
            ;;
        *)
            echo $'\e[31mInvalid choice. Exiting...\e[0m'
            exit
            ;;
    esac
    bash "$0"

# If option 9 is selected
elif [ "$choice" -eq 9 ]; then
    echo $'\e[32mInstalling BBR, please wait...\e[0m' && \
    wget -N --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh && \
    chmod +x bbr.sh && \
    bash bbr.sh
    bash "$0"

# If option 10 is selected
elif [ "$choice" -eq 10 ]; then
    read -p $'\e[91mWarning\e[33m: This will uninstall Gost and remove all related data. Are you sure you want to continue? (y/n): ' uninstall_confirm

    if [ "$uninstall_confirm" == "y" ]; then
        echo $'\e[32mUninstalling Gost in 3 seconds... \e[0m' && sleep 1 && echo $'\e[32m2... \e[0m' && sleep 1 && echo $'\e[32m1... \e[0m' && sleep 1 && {
            rm -f /usr/bin/auto_restart_cronjob.sh
            crontab -l 2>/dev/null | grep -v '/usr/bin/auto_restart_cronjob.sh' | crontab -
            remove_watchdog
            systemctl daemon-reload
            systemctl stop gost_*.service 2>/dev/null
            rm -f /usr/local/bin/gost
            rm -rf /etc/gost
            rm -f /usr/lib/systemd/system/gost_*.service
            rm -f /etc/systemd/system/multi-user.target.wants/gost_*.service
            systemctl stop sysctl-custom 2>/dev/null
            systemctl disable sysctl-custom 2>/dev/null
            rm -f /etc/systemd/system/sysctl-custom.service
            rm -f /etc/systemd/system/multi-user.target.wants/sysctl-custom.service
            systemctl daemon-reload
            echo $'\e[32mGost successfully uninstalled.\e[0m'
        }
    else
        echo $'\e[32mUninstallation canceled.\e[0m'
    fi

# If option 11 is selected
elif [ "$choice" -eq 11 ]; then
    apply_optimizations
    echo $'\e[32mOptimizations applied successfully.\e[0m'
    bash "$0"

# If option 12 is selected
elif [ "$choice" -eq 12 ]; then
    install_watchdog
    echo $'\e[32mAuto-Heal watchdog installed successfully.\e[0m'
    bash "$0"

# If option 13 is selected
elif [ "$choice" -eq 13 ]; then
    remove_watchdog
    bash "$0"

# If option 14 is selected
elif [ "$choice" -eq 14 ]; then
    echo $'\e[32mYou have exited the script.\e[0m'
    exit
fi
