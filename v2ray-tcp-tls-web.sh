#!/bin/bash

# ----------------1
if [ -z "$1" ]; then
    echo "域名不能为空"
    exit
fi
if [ -z "$2" ]; then
    echo "请指定监听端口"
    exit
fi
if [ $(id -u) -ne 0 ]; then
    echo "需要root用户"
    exit
fi

# ----------------2
ufw disable

apt clean all && apt update
apt install haproxy nginx curl openssl cron socat uuid-runtime -y || {
    dpkg --configure -a
    apt --fix-broken install -y
    apt install haproxy nginx curl openssl cron socat uuid-runtime -y
}

bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

systemctl enable haproxy
systemctl enable nginx
systemctl enable v2ray

systemctl stop haproxy
systemctl stop nginx
systemctl stop v2ray

# ----------------3
domainName="$1"
portOutter="$2"
portInnerV2ray="$(shuf -i 20000-45000 -n 1)"
portInnerNginx="$(shuf -i 45000-65000 -n 1)"
uuid="$(uuidgen)"

haproxyConfig="/etc/haproxy/haproxy.cfg"
nginxConfig="/etc/nginx/conf.d/v2ray.conf"
v2rayConfig="/usr/local/etc/v2ray/config.json"

local_ip="$(
    curl ifconfig.me 2>/dev/null
    echo
)"
resolve_ip="$(host "$domainName" | awk '{print $NF}')"
if [ "$local_ip" != "$resolve_ip" ]; then
    echo "域名解析不正确"
    exit 9
fi

# ----------------4
sslDir="/root/.acme.sh/${domainName}_ecc"

if ! [ -d /root/.acme.sh ]; then curl https://get.acme.sh | sh; fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$domainName" --standalone --keylength ec-256 --force
cat ${sslDir}/fullchain.cer ${sslDir}/${domainName}.key > ${sslDir}/${domainName}.pem

echo -n "#!/bin/bash
/etc/init.d/nginx stop
wait;/root/.acme.sh/acme.sh --cron --home /root/.acme.sh --force &> /root/renew_ssl.log
wait;cat ${sslDir}/fullchain.cer ${sslDir}/${domainName}.key > ${sslDir}/${domainName}.pem
wait;/etc/init.d/nginx start
wait;/etc/init.d/haproxy restart
" >/usr/local/bin/ssl_renew.sh
chmod +x /usr/local/bin/ssl_renew.sh
(
    crontab -l
    echo "15 03 * * * /usr/local/bin/ssl_renew.sh"
) | crontab

# ----------------5
echo '
{
    "inbounds": [
        {
            "protocol": "vmess",
            "listen": "127.0.0.1",
            "port": '$portInnerV2ray',
            "settings": {
                "clients": [
                    {
                        "id": '"\"$uuid\""'
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
' > $v2rayConfig

echo "
server {
  listen $portInnerNginx;
  server_name $domainName;
  root /var/www/html;
}
" > $nginxConfig

echo "
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private

    # 仅使用支持 FS 和 AEAD 的加密套件
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    # 禁用 TLS 1.2 之前的 TLS
    ssl-default-bind-options no-sslv3 no-tlsv10 no-tlsv11

    tune.ssl.default-dh-param 2048

defaults
    log global
    # 我们需要使用 tcp 模式
    mode tcp
    option dontlognull
    timeout connect 5s
    # 空闲连接等待时间，这里使用与 V2Ray 默认 connIdle 一致的 300s
    timeout client  300s
    timeout server  300s

frontend tls-in
    # 监听 443 tls，tfo 根据自身情况决定是否开启，证书放置于 /etc/ssl/private/example.com.pem
    bind *:${portOutter} tfo ssl crt ${sslDir}/${domainName}.pem
    tcp-request inspect-delay 5s
    tcp-request content accept if HTTP
    # 将 HTTP 流量发给 web 后端
    use_backend web if HTTP
    # 将其他流量发给 vmess 后端
    default_backend vmess

backend web
    server server1 127.0.0.1:$portInnerNginx

backend vmess
    server server1 127.0.0.1:$portInnerV2ray
" > $haproxyConfig

# ----------------6
systemctl restart haproxy
systemctl restart nginx
systemctl restart v2ray

# ----------------7
echo "
域名: $domainName
端口: $portOutter
UUID: $uuid
方式: tcp + tls + web
"
