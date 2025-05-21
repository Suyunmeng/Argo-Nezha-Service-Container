#!/usr/bin/env bash

# 首次运行时执行以下流程，再次运行时存在 /etc/supervisor/conf.d/damon.conf 文件，直接到最后一步
if [ ! -s /etc/supervisor/conf.d/damon.conf ]; then

  # 设置 Github CDN 及若干变量，如是 IPv6 only 或者大陆机器，需要 Github 加速网，可自行查找放在 GH_PROXY 处 ，如 https://ghproxy.lvedong.eu.org/ ，能不用就不用，减少因加速网导致的故障。
  GH_PROXY='https://ghproxy.lvedong.eu.org/'
  GRPC_PROXY_PORT=443
  GRPC_PORT=8008
  WEB_PORT=8080
  PRO_PORT=${PRO_PORT:-'80'}
  BACKUP_TIME=${BACKUP_TIME:-'0 4 * * *'}
  CADDY_HTTP_PORT=2052
  WORK_DIR=/dashboard

  # 如不分离备份的 github 账户，默认与哪吒登陆的 github 账户一致
  GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}

  error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
  info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
  hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

  # 如参数不齐全，容器退出，另外处理某些环境变量填错后的处理
  if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    [[ -z "$GH_USER" || -z "$GH_CLIENTID" || -z "$GH_CLIENTSECRET" || -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]] && error " There are variables that are not set. "
  else
    [[ -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]] && error " There are argo variables that are not set. "
  fi
  [[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")  # Json 时，没有了"的处理
  [[ "$ARGO_AUTH" =~ ey[A-Z0-9a-z=]{120,250}$ ]] && ARGO_AUTH=$(awk '{print $NF}' <<< "$ARGO_AUTH") # Token 复制全部，只取最后的 ey 开始的
  [ -n "$GH_REPO" ] && grep -q '/' <<< "$GH_REPO" && GH_REPO=$(awk -F '/' '{print $NF}' <<< "$GH_REPO")  # 填了项目全路径的处理

  # 检测是否需要启用 Github CDN，如能直接连通，则不使用
  [ -n "$GH_PROXY" ] && wget --server-response --quiet --output-document=/dev/null --no-check-certificate --tries=2 --timeout=3 https://raw.githubusercontent.com/Kiritocyz/Argo-Nezha-Service-Container/main/README.md >/dev/null 2>&1 && unset GH_PROXY

  # 设置 DNS
  echo -e "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8844\nnameserver 2400:3200::1\n" > /etc/resolv.conf

  # 设置 +8 时区 (北京时间)
  ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata

  # 判断处理器架构
  case "$(uname -m)" in
    aarch64|arm64 )
      ARCH=arm64
      ;;
    x86_64|amd64 )
      ARCH=amd64
      ;;
    armv7* )
      ARCH=arm
      ;;
    * ) error " $(text 2) "
  esac

  # 用户选择使用 gRPC 反代方式: Nginx / Caddy / grpcwebproxy，默认为 Caddy；如需使用 grpcwebproxy，把 REVERSE_PROXY_MODE 的值设为 nginx 或 grpcwebproxy
  if [ "$REVERSE_PROXY_MODE" = 'grpcwebproxy' ]; then
    wget -c ${GH_PROXY}https://github.com/Suyunmeng/Argo-Nezha-Service-Container/releases/download/grpcwebproxy/grpcwebproxy-linux-$ARCH.tar.gz -qO- | tar xz -C $WORK_DIR
    chmod +x $WORK_DIR/grpcwebproxy
    GRPC_PROXY_RUN="$WORK_DIR/grpcwebproxy --server_tls_cert_file=$WORK_DIR/nezha.pem --server_tls_key_file=$WORK_DIR/nezha.key --server_http_tls_port=$GRPC_PROXY_PORT --backend_addr=localhost:$GRPC_PORT --backend_tls_noverify --server_http_max_read_timeout=300s --server_http_max_write_timeout=300s"
  elif [ "$REVERSE_PROXY_MODE" = 'nginx' ]; then
    GRPC_PROXY_RUN='nginx -g "daemon off;"'
    if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
      cat > /etc/nginx/nginx.conf  << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
        worker_connections 768;
        # multi_accept on;
}
http {
  upstream grpcservers {
    server localhost:$GRPC_PORT;
    keepalive 1024;
  }
  server {
    listen 127.0.0.1:$GRPC_PROXY_PORT ssl http2;
    server_name $ARGO_DOMAIN;
    ssl_certificate          $WORK_DIR/nezha.pem;
    ssl_certificate_key      $WORK_DIR/nezha.key;
    underscores_in_headers on;
    location / {
      grpc_read_timeout 300s;
      grpc_send_timeout 300s;
      grpc_socket_keepalive on;
      grpc_pass grpc://grpcservers;
    }
    access_log  /dev/null;
    error_log   /dev/null;
  }
}
EOF
    else
      cat > /etc/nginx/nginx.conf  << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
        worker_connections 768;
        # multi_accept on;
}
http {
  upstream dashboard {
    server localhost:$GRPC_PORT;
    keepalive 512;
  }
  server {
    listen localhost:$GRPC_PROXY_PORT ssl http2;
    server_name $ARGO_DOMAIN;
    ssl_certificate          $WORK_DIR/nezha.pem;
    ssl_certificate_key      $WORK_DIR/nezha.key;
    ssl_stapling on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m; # 如果与其他配置冲突，请注释此项
    ssl_protocols TLSv1.2 TLSv1.3;

    underscores_in_headers on;
    set_real_ip_from 0.0.0.0/0; # 替换为你的 CDN 回源 IP 地址段
    real_ip_header CF-Connecting-IP; # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
    # 如果你使用nginx作为最外层，把上面两行注释掉

    # grpc 相关    
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host $host;
        grpc_set_header nz-realip $http_CF_Connecting_IP; # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
        # grpc_set_header nz-realip $remote_addr; # 如果你使用nginx作为最外层，就把上面一行注释掉，启用此行
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }
    # websocket 相关
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $http_cf_connecting_ip; # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
        proxy_set_header nz-realip $remote_addr; # 如果你使用nginx作为最外层，就把上面一行注释掉，启用此行
        proxy_set_header Origin https://$host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:$GRPC_PORT;
    }
    # web
    location / {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $http_cf_connecting_ip; # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
        proxy_set_header nz-realip $remote_addr; # 如果你使用nginx作为最外层，就把上面一行注释掉，启用此行
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:$GRPC_PORT;
    }
  }
}
EOF
    fi
  else
    CADDY_LATEST=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/caddyserver/caddy/releases/latest" | awk -F [v\"] '/"tag_name"/{print $5}' || echo '2.7.6')
    wget -c ${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz -qO- | tar xz -C $WORK_DIR caddy
    GRPC_PROXY_RUN="$WORK_DIR/caddy run --config $WORK_DIR/Caddyfile --watch"
    if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
      cat > $WORK_DIR/Caddyfile  << EOF
{
    http_port $CADDY_HTTP_PORT
}

:$GRPC_PROXY_PORT {
    reverse_proxy {
        to localhost:$GRPC_PORT
        transport http {
            versions h2c 2
        }
    }
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}

:$PRO_PORT {
    reverse_proxy {
        to localhost:$WEB_PORT
    }
}

https://localhost:3106 {                                                                                                                                                                                          
    tls internal                                                                                                                                                                                                  
                                                                                                                                                                                                              
    reverse_proxy http://localhost:3006 {                                                                                                                                                                                                                                                                                                                                                                          
        transport http {                                                                                                                                                                                          
            versions h2c                                                                                                                                                                                          
        }                                                                                                                                                                                                         
        header_up X-Forwarded-For {remote_host}                                                                                                                                                                   
    }                                                                                                                                                                                                             
}   

https://localhost:3107 {                                                                                                                                                                                          
    tls internal                                                                                                                                                                                                  
                                                                                                                                                                                                              
    reverse_proxy http://localhost:3007 {                                                                                                                                                                                                                                                                                                                                                                             
        transport http {                                                                                                                                                                                          
            versions h2c                                                                                                                                                                                          
        }                                                                                                                                                                                                         
        header_up X-Forwarded-For {remote_host}                                                                                                                                                                   
    }                                                                                                                                                                                                             
} 
EOF
    else
      cat > $WORK_DIR/Caddyfile  << EOF
{
    http_port $CADDY_HTTP_PORT
}

:$GRPC_PROXY_PORT {
    @grpcProto {
        path /proto.NezhaService/*
    }

    reverse_proxy @grpcProto {
        header_up Host {host}
        header_up nz-realip {http.CF-Connecting-IP} # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
        header_up nz-realip {remote_host} # 如果你使用caddy作为最外层，就把上面一行注释掉，启用此行
        transport http {
            versions h2c
            read_buffer 4096
        }
        to localhost:$GRPC_PORT
    }
    reverse_proxy {
        header_up Host {host}
        header_up Origin https://{host}
        header_up nz-realip {http.CF-Connecting-IP} # 替换为你的 CDN 提供的私有 header，此处为 CloudFlare 默认
        header_up nz-realip {remote_host} # 如果你使用caddy作为最外层，就把上面一行注释掉，启用此行
        header_up Upgrade {http.upgrade}
        header_up Connection "upgrade"
        transport http {
            read_buffer 16384
        }
        to localhost:$GRPC_PORT
    }
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}

https://localhost:3106 {                                                                                                                                                                                          
    tls internal                                                                                                                                                                                                  
                                                                                                                                                                                                              
    reverse_proxy http://localhost:3006 {                                                                                                                                                                                                                                                                                                                                                                          
        transport http {                                                                                                                                                                                          
            versions h2c                                                                                                                                                                                          
        }                                                                                                                                                                                                         
        header_up X-Forwarded-For {remote_host}                                                                                                                                                                   
    }                                                                                                                                                                                                             
}   

https://localhost:3107 {                                                                                                                                                                                          
    tls internal                                                                                                                                                                                                  
                                                                                                                                                                                                              
    reverse_proxy http://localhost:3007 {                                                                                                                                                                                                                                                                                                                                                                             
        transport http {                                                                                                                                                                                          
            versions h2c                                                                                                                                                                                          
        }                                                                                                                                                                                                         
        header_up X-Forwarded-For {remote_host}                                                                                                                                                                   
    }                                                                                                                                                                                                             
} 
EOF
    fi
  fi

  # 下载需要的应用
  if [ -z "$DASHBOARD_VERSION" ]; then
    wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/nezhahq/nezha/releases/latest/download/dashboard-linux-$ARCH.zip
    wget -O $WORK_DIR/nezha-agent.zip ${GH_PROXY}https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_$ARCH.zip
  elif [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    [-z "$GH_USER" || -z "$GH_CLIENTID" || -z "$GH_CLIENTSECRET"] && error " There are github variables that are not set. "
    DASHBOARD_LATEST=$(sed 's/v//; s/^/v&/' <<< "$DASHBOARD_VERSION")
    wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/naiba/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    wget -O $WORK_DIR/nezha-agent.zip ${GH_PROXY}https://github.com/nezhahq/agent/releases/download/v0.20.5/nezha-agent_linux_$ARCH.zip
  else
    error "The DASHBOARD_VERSION variable is not in the correct format, please check."
  fi
  unzip -o /tmp/dashboard.zip -d /tmp
  [ -d /tmp/dist ] && mv /tmp/dist/dashboard-linux-$ARCH /tmp/dashboard-linux-$ARCH
  chmod +x /tmp/dashboard-linux-$ARCH
  mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/app
  wget -qO $WORK_DIR/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
  unzip -o $WORK_DIR/nezha-agent.zip -d $WORK_DIR/
  rm -rf $WORK_DIR/nezha-agent.zip /tmp/dist /tmp/dashboard.zip

  # 根据参数生成哪吒服务端配置文件
  [ ! -d data ] && mkdir data
  if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    cat > ${WORK_DIR}/data/config.yaml << EOF
Debug: false
HTTPPort: $WEB_PORT
Language: zh-CN
GRPCPort: $GRPC_PORT
GRPCHost: $ARGO_DOMAIN
ProxyGRPCPort: $GRPC_PROXY_PORT
TLS: true
Oauth2:
  Type: "github" #Oauth2 登录接入类型，github/gitlab/jihulab/gitee/gitea ## Argo-容器版本只支持 github
  Admin: "$GH_USER" #管理员列表，半角逗号隔开
  ClientID: "$GH_CLIENTID" # 在 ${GH_PROXY}https://github.com/settings/developers 创建，无需审核 Callback 填 http(s)://域名或IP/oauth2/callback
  ClientSecret: "$GH_CLIENTSECRET"
  Endpoint: "" # 如gitea自建需要设置 ## Argo-容器版本只支持 github
site:
  Brand: "Nezha Probe"
  Cookiename: "nezha-dashboard" #浏览器 Cookie 字段名，可不改
  Theme: "default"
EOF
  else
    LOCAL_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    AGENT_UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    cat > ${WORK_DIR}/data/config.yaml << EOF
agent_secret_key: $LOCAL_TOKEN
debug: false
listen_port: $GRPC_PORT
language: zh-CN
site_name: "Nezha Probe"
install_host: $ARGO_DOMAIN:$GRPC_PROXY_PORT
location: Asia/Shanghai
tls: true
EOF
    if [[ -n "$GH_CLIENTID" && -n "$GH_CLIENTSECRET" ]]; then
      cat >> ${WORK_DIR}/data/config.yaml << EOF
oauth2:
   GitHub:
     client_id: "$GH_CLIENTID"
     client_secret: "$GH_CLIENTSECRET"
     endpoint:
       auth_url: "https://github.com/login/oauth/authorize"
       token_url: "https://github.com/login/oauth/access_token"
     user_info_url: "https://api.github.com/user"
     user_id_path: "id"
EOF
    fi
    cat > ${WORK_DIR}/data/config.yml << EOF
client_secret: $LOCAL_TOKEN
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: true
ip_report_period: 1800
report_delay: 3
server: $ARGO_DOMAIN:$GRPC_PROXY_PORT
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: true
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $AGENT_UUID
EOF
  fi

  if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    # 下载包含本地数据的 sqlite.db 文件，生成18位随机字符串用于本地 Token
    wget -P ${WORK_DIR}/data/ ${GH_PROXY}https://github.com/Suyunmeng/Argo-Nezha-Service-Container/raw/main/sqlite.db
    LOCAL_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)
    sqlite3 ${WORK_DIR}/data/sqlite.db "update servers set secret='${LOCAL_TOKEN}' where created_at='2023-04-23 13:02:00.770756566+08:00'"
  fi

  if [[ -n "$GH_CLIENTID" && -n "$GH_CLIENTSECRET" ]]; then
    # SSH path 与 GH_CLIENTID 一样
    echo root:"$GH_CLIENTSECRET" | chpasswd root
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    service ssh restart
  fi

  # 判断 ARGO_AUTH 为 json 还是 token
  # 如为 json 将生成 argo.json 和 argo.yml 文件
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    ARGO_RUN="cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/argo.yml run"

    echo "$ARGO_AUTH" > $WORK_DIR/argo.json

    cat > $WORK_DIR/argo.yml << EOF
tunnel: $(cut -d '"' -f12 <<< "$ARGO_AUTH")
credentials-file: $WORK_DIR/argo.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:$GRPC_PROXY_PORT
    path: /proto.NezhaService/*
    originRequest:
      http2Origin: true
      noTLSVerify: true
  - hostname: $ARGO_DOMAIN
    service: ssh://localhost:22
    path: /$GH_CLIENTID/*
  - hostname: $ARGO_DOMAIN
EOF
    if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
      cat >> $WORK_DIR/argo.yml << EOF
    service: http://localhost:$WEB_PORT
  - service: http_status:404
EOF
    else
      cat >> $WORK_DIR/argo.yml << EOF
    service: http://localhost:$PRO_PORT
  - service: http_status:404
EOF
    fi
  # 如为 token 时
  elif [[ "$ARGO_AUTH" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
    ARGO_RUN="cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
  fi

  # 生成自签署SSL证书
  openssl genrsa -out $WORK_DIR/nezha.key 2048
  openssl req -new -subj "/CN=$ARGO_DOMAIN" -key $WORK_DIR/nezha.key -out $WORK_DIR/nezha.csr
  openssl x509 -req -days 36500 -in $WORK_DIR/nezha.csr -signkey $WORK_DIR/nezha.key -out $WORK_DIR/nezha.pem

  # 生成 backup.sh 文件的步骤1 - 设置环境变量
  cat > $WORK_DIR/backup.sh << EOF
#!/usr/bin/env bash

# backup.sh 传参 a 自动还原； 传参 m 手动还原； 传参 f 强制更新面板 app 文件及 cloudflared 文件，并备份数据至成备份库

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_EMAIL=$GH_EMAIL
GH_REPO=$GH_REPO
ARCH=$ARCH
WORK_DIR=$WORK_DIR
DAYS=5
IS_DOCKER=1
DASHBOARD_VERSION=$DASHBOARD_VERSION

########
EOF

  # 生成 backup.sh 文件的步骤2 - 在线获取 template/bakcup.sh 模板生成完整 backup.sh 文件
  wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/Suyunmeng/Argo-Nezha-Service-Container/main/template/backup.sh | sed '1,/^########/d' >> $WORK_DIR/backup.sh

  if [[ -n "$GH_BACKUP_USER" && -n "$GH_EMAIL" && -n "$GH_REPO" && -n "$GH_PAT" ]]; then
    # 生成 restore.sh 文件的步骤1 - 设置环境变量
    cat > $WORK_DIR/restore.sh << EOF
#!/usr/bin/env bash

# restore.sh 传参 a 自动还原 README.md 记录的文件，当本地与远程记录文件一样时不还原； 传参 f 不管本地记录文件，强制还原成备份库里 README.md 记录的文件； 传参 dashboard-***.tar.gz 还原成备份库里的该文件；不带参数则要求选择备份库里的文件名

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_REPO=$GH_REPO
WORK_DIR=$WORK_DIR
TEMP_DIR=/tmp/restore_temp
NO_ACTION_FLAG=/tmp/flag
IS_DOCKER=1

########
EOF

    # 生成 restore.sh 文件的步骤2 - 在线获取 template/restore.sh 模板生成完整 restore.sh 文件
    wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/Suyunmeng/Argo-Nezha-Service-Container/main/template/restore.sh | sed '1,/^########/d' >> $WORK_DIR/restore.sh
  fi

  # 生成 renew.sh 文件的步骤1 - 设置环境变量
  cat > $WORK_DIR/renew.sh << EOF
#!/usr/bin/env bash

GH_PROXY=$GH_PROXY
WORK_DIR=/dashboard
TEMP_DIR=/tmp/renew

########
EOF

  # 生成 renew.sh 文件的步骤2 - 在线获取 template/renew.sh 模板生成完整 renew.sh 文件
  wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/Suyunmeng/Argo-Nezha-Service-Container/main/template/renew.sh | sed '1,/^########/d' >> $WORK_DIR/renew.sh

  # 生成定时任务: 1.每天北京时间 3:30:00 更新备份和还原文件，2.每天北京时间 4:00:00 备份一次，并重启 cron 服务； 3.每分钟自动检测在线备份文件里的内容
  [ -z "$NO_AUTO_RENEW" ] && [ -s $WORK_DIR/renew.sh ] && ! grep -q "$WORK_DIR/renew.sh" /etc/crontab && echo "30 3 * * * root bash $WORK_DIR/renew.sh" >> /etc/crontab
  [ -s $WORK_DIR/backup.sh ] && ! grep -q "$WORK_DIR/backup.sh" /etc/crontab && echo "$BACKUP_TIME root bash $WORK_DIR/backup.sh a" >> /etc/crontab
  [ -s $WORK_DIR/restore.sh ] && ! grep -q "$WORK_DIR/restore.sh" /etc/crontab && echo "* * * * * root bash $WORK_DIR/restore.sh a" >> /etc/crontab
  service cron restart

if [ -n "$ID" ] && [ "$ID" != "0" ]; then
  # 启动xxxry
  echo -e "cd /app\nnode /app/index.js" > /app/bash.sh
  chmod +x /app/bash.sh
  WEB_RUN="/app/bash.sh"
fi
if [[ "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
   AG_RUN="$WORK_DIR/nezha-agent -s localhost:$GRPC_PORT -p $LOCAL_TOKEN --disable-auto-update --disable-force-update"
else
   AG_RUN="$WORK_DIR/nezha-agent -c $WORK_DIR/data/config.yml"
fi
  # 生成 supervisor 进程守护配置文件
  cat > /etc/supervisor/conf.d/damon.conf << EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:grpcproxy]
command=$GRPC_PROXY_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:nezha]
command=$WORK_DIR/app
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:agent]
command=$AG_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:argo]
command=$WORK_DIR/$ARGO_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF
if [ -n "$IID" ] && [ "$IID" != "0" ]; then
    cat >> /etc/supervisor/conf.d/damon.conf << EOF

[program:webapp]
command=$WEB_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF
get_country_code() {
    country_code="UN"
    urls=("http://ipinfo.io/country" "https://ifconfig.co/country" "https://ipapi.co/country")

    for url in "${urls[@]}"; do
        if [ "$download_tool" = "curl" ]; then
            country_code=$(curl -s "$url")
        else
            country_code=$(wget -qO- "$url")
        fi

        if [ -n "$country_code" ] && [ ${#country_code} -eq 2 ]; then
            break
        fi
    done

    echo "     国家:    $country_code"
}
get_country_code
fi
  # 赋执行权给 sh 及所有应用
  chmod +x $WORK_DIR/{cloudflared,app,nezha-agent,*.sh}

fi

# 运行 supervisor 进程守护
supervisord -c /etc/supervisor/supervisord.conf