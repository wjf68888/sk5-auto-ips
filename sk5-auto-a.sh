#!/usr/bin/env bash
set -e

# ========== 1. 自动提权 ==========
if [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "检测到当前非root，尝试sudo提权运行脚本..."
    exec sudo bash "$0" "$@"
  else
    echo "请以 root 用户或有 sudo 权限的用户执行本脚本！"
    exit 1
  fi
fi

# ========== 2. 获取参数 ==========
if [ $# -lt 1 ]; then
  echo "用法: bash sk5_deploy.sh <实例数量>"
  exit 1
fi
INSTANCE_NUM="$1"
if ! [[ "$INSTANCE_NUM" =~ ^[0-9]+$ ]] || [ "$INSTANCE_NUM" -le 0 ]; then
  echo "实例数量必须为正整数！"
  exit 1
fi

# ========== 3. 安装依赖 ==========
REQUIRED_PKGS=(git gcc make iproute2 iptables iptables-persistent curl)
install_list=()
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    install_list+=("$pkg")
  fi
done
if [ ${#install_list[@]} -gt 0 ]; then
  apt-get update -qq
  apt-get install -qq -y "${install_list[@]}"
fi

# ========== 4. 安装 microsocks ==========
MICROSOCKS_BIN="/usr/local/bin/microsocks"
if ! command -v microsocks >/dev/null 2>&1; then
  cd /tmp
  if [ ! -d "microsocks" ]; then
    git clone https://github.com/rofl0r/microsocks.git
  fi
  cd microsocks
  make clean
  make
  cp microsocks "$MICROSOCKS_BIN"
  chmod +x "$MICROSOCKS_BIN"
fi

# ========== 5. 获取全部公网IP ==========
mapfile -t ALL_IPS < <(ip -4 addr show | awk '/inet /{sub(/\/.*/,"",$2); print $2}' | grep -Ev '^(10\.|172\.|192\.168\.|127\.)')
PUBIP_NUM=${#ALL_IPS[@]}
[ $PUBIP_NUM -gt 0 ] || { echo "未检测到公网IP"; exit 1; }

# ========== 6. 生成端口和 systemd 单元 ==========
declare -a IPS PORTS
for ((i=0; i<INSTANCE_NUM; i++)); do
  idx=$(( PUBIP_NUM > 0 ? i % PUBIP_NUM : 0 ))
  IPS[i]="${ALL_IPS[$idx]}"
  while :; do
    p=$((RANDOM%20000+30000))
    ss -lunt | grep -q ":$p " || { PORTS[i]=$p; break; }
  done
done

# ========== 7. 创建 systemd 单元 ==========
for ((i=0; i<INSTANCE_NUM; i++)); do
  ip="${IPS[$i]}"
  port="${PORTS[$i]}"
  cat > /etc/systemd/system/sk5_${ip}_${port}.service <<EOF
[Unit]
Description=microsocks instance for ${ip}:${port}
After=network.target

[Service]
Type=simple
ExecStart=$MICROSOCKS_BIN -i $ip -p $port
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
done

systemctl daemon-reload
for ((i=0; i<INSTANCE_NUM; i++)); do
  ip="${IPS[$i]}" port="${PORTS[$i]}"
  systemctl enable sk5_${ip}_${port}
  systemctl restart sk5_${ip}_${port}
done

# ========== 8. 生成批量导入文件 ==========
mkdir -p /var/www/html

echo "# Socks5批量导入（格式：ip:端口）" > /var/www/html/sk5_servers.txt
for ((i=0; i<INSTANCE_NUM; i++)); do
  ip="${IPS[$i]}"
  port="${PORTS[$i]}"
  echo "${ip}:${port}" >> /var/www/html/sk5_servers.txt
done

# ========== 9. 持久化iptables ==========
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# ========== 10. 部署自恢复 ==========
cat > /etc/systemd/system/sk5-bootstrap.service <<EOF
[Unit]
Description=SK5一键部署 & 重建服务
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash $0 $INSTANCE_NUM
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sk5-bootstrap.service

echo "全部部署完成！Socks5批量导入地址：http://$(hostname -I | awk '{print $1}')/sk5_servers.txt"
