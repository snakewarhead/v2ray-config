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
portInner="$(shuf -i 20000-65000 -n 1)"
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
if ! [ -d /root/.acme.sh ]; then curl https://get.acme.sh | sh; fi
~/.acme.sh/acme.sh --issue -d "$domainName" --standalone --keylength ec-256 --force

echo -n "#!/bin/bash
/etc/init.d/nginx stop
wait;/root/.acme.sh/acme.sh --cron --home /root/.acme.sh &> /root/renew_ssl.log
wait;cat /root/.acme.sh/${domainName}_ecc/fullchain.cer /root/.acme.sh/${domainName}_ecc/${domainName}.key > /root/.acme.sh/${domainName}_ecc/${domainName}.pem
wait;/etc/init.d/nginx start
" >/usr/local/bin/ssl_renew.sh
chmod +x /usr/local/bin/ssl_renew.sh
(
    crontab -l
    echo "15 03 * * * /usr/local/bin/ssl_renew.sh"
) | crontab
