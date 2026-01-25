#!/usr/bin/env bash

# =============================================================================
# ERPNext Universal Installation Script - Complete Version
# Features: Multiple installations, Additional apps, SSL, All versions
# Fixed: Network timeout issues, Supervisor, Production setup
# =============================================================================

set -e

server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

# Colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

SUPPORTED_DISTRIBUTIONS=("Ubuntu" "Debian")
SUPPORTED_VERSIONS=("24.04" "23.04" "22.04" "20.04" "12" "11" "10")

# Global variables
DEFAULT_PASSWORD="ChangeMe123!"
INSTALL_USER=""
INSTALL_HOME=""
BENCH_NAME=""
SITE_NAME=""
SQL_PASSWORD=""
ADMIN_PASSWORD=""
EMAIL_ADDRESS=""
BENCH_VERSION=""

# =============================================================================
# NETWORK & PIP CONFIGURATION - FIXED
# =============================================================================

configure_pip_for_network() {
    echo -e "${YELLOW}Configuring pip for better network performance...${NC}"
    
    mkdir -p ~/.pip
    cat > ~/.pip/pip.conf << 'EOF'
[global]
timeout = 300
retries = 10
index-url = https://pypi.org/simple
trusted-host = pypi.org
               pypi.python.org
               files.pythonhosted.org
[install]
compile = no
EOF

    sudo mkdir -p /root/.pip
    sudo tee /root/.pip/pip.conf > /dev/null << 'EOF'
[global]
timeout = 300
retries = 10
index-url = https://pypi.org/simple
trusted-host = pypi.org
               pypi.python.org
               files.pythonhosted.org
[install]
compile = no
EOF

    export PIP_DEFAULT_TIMEOUT=300
    export PIP_RETRIES=10
    export PIP_NO_CACHE_DIR=1

    echo -e "${GREEN}✓ Pip configuration completed${NC}"
}

# =============================================================================
# SYSTEM CHECKS
# =============================================================================

check_os() {
    local os_name=$(lsb_release -is 2>/dev/null)
    local os_version=$(lsb_release -rs 2>/dev/null)
    local os_supported=false
    local version_supported=false

    for i in "${SUPPORTED_DISTRIBUTIONS[@]}"; do
        [[ "$i" = "$os_name" ]] && os_supported=true && break
    done

    for i in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "$i" = "$os_version" ]] && version_supported=true && break
    done

    if [[ "$os_supported" = false ]] || [[ "$version_supported" = false ]]; then
        echo -e "${RED}OS not supported: $os_name $os_version${NC}"
        exit 1
    fi
}

check_os

# Detect distribution
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        DISTRO='Ubuntu'
    else
        DISTRO='Debian'
    fi
fi

# =============================================================================
# CHECK EXISTING INSTALLATIONS
# =============================================================================

check_existing_installations() {
    local existing=()
    
    echo -e "${YELLOW}Checking for existing ERPNext installations...${NC}"
    
    for path in $HOME/frappe-bench* /home/*/frappe-bench*; do
        if [[ -d "$path" ]] && [[ -f "$path/apps/frappe/frappe/__init__.py" ]]; then
            existing+=("$path")
        fi
    done
    
    if [[ ${#existing[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}⚠️  EXISTING INSTALLATIONS DETECTED ⚠️${NC}"
        echo ""
        for inst in "${existing[@]}"; do
            echo -e "${LIGHT_BLUE}• $inst${NC}"
        done
        echo ""
        echo -e "${YELLOW}Multiple versions can cause conflicts!${NC}"
        echo ""
        
        read -p "Continue anyway? (yes/no): " confirm
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
            echo -e "${GREEN}Installation cancelled${NC}"
            exit 0
        fi
    else
        echo -e "${GREEN}✓ No existing installations found${NC}"
    fi
}

# =============================================================================
# USER INPUT FUNCTIONS
# =============================================================================

ask_twice() {
    local prompt="$1"
    local secret="$2"
    local val1 val2

    while true; do
        if [ "$secret" = "true" ]; then
            read -rsp "$prompt: " val1
            echo >&2
            read -rsp "Confirm password: " val2
            echo >&2
        else
            read -rp "$prompt: " val1
            echo >&2
            read -rp "Confirm: " val2
            echo >&2
        fi

        if [ "$val1" = "$val2" ]; then
            echo -e "${GREEN}✓ Confirmed${NC}" >&2
            echo "$val1"
            break
        else
            echo -e "${RED}Mismatch! Try again${NC}" >&2
        fi
    done
}

select_or_create_user() {
    echo -e "${YELLOW}Select installation user:${NC}"
    echo "1. Current user ($(whoami))"
    echo "2. Create new user"
    echo "3. Existing user"
    
    read -p "Choice (1-3): " choice
    
    case $choice in
        1)
            INSTALL_USER=$(whoami)
            [[ "$INSTALL_USER" = "root" ]] && echo -e "${RED}Cannot use root${NC}" && return 1
            INSTALL_HOME=$HOME
            ;;
        2)
            read -p "New username: " new_user
            [[ -z "$new_user" ]] && echo -e "${RED}Empty username${NC}" && return 1
            
            if ! id "$new_user" &>/dev/null; then
                sudo adduser --disabled-password --gecos "" "$new_user"
                sudo usermod -aG sudo "$new_user"
                echo "$new_user:$DEFAULT_PASSWORD" | sudo chpasswd
                echo -e "${GREEN}✓ User created. Password: $DEFAULT_PASSWORD${NC}"
            fi
            INSTALL_USER="$new_user"
            INSTALL_HOME="/home/$new_user"
            ;;
        3)
            read -p "Username: " existing_user
            ! id "$existing_user" &>/dev/null && echo -e "${RED}User not found${NC}" && return 1
            INSTALL_USER="$existing_user"
            INSTALL_HOME="/home/$existing_user"
            ;;
        *)
            INSTALL_USER=$(whoami)
            INSTALL_HOME=$HOME
            ;;
    esac
    
    echo -e "${GREEN}✓ User: $INSTALL_USER${NC}"
    return 0
}

collect_info() {
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}    PRE-INSTALLATION INFORMATION           ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════${NC}"
    
    while ! select_or_create_user; do
        echo -e "${RED}Try again${NC}"
    done
    
    read -p "Bench folder (default: frappe-bench): " BENCH_NAME
    BENCH_NAME=${BENCH_NAME:-frappe-bench}
    
    read -p "Site name: " SITE_NAME
    while [[ -z "$SITE_NAME" ]]; do
        read -p "Site name (required): " SITE_NAME
    done
    
    SQL_PASSWORD=$(ask_twice "SQL root password" "true")
    ADMIN_PASSWORD=$(ask_twice "Administrator password" "true")
    
    read -p "Email (for SSL, optional): " EMAIL_ADDRESS
    
    echo ""
}

show_summary() {
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}         INSTALLATION SUMMARY              ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}User:${NC}    $INSTALL_USER"
    echo -e "${GREEN}Home:${NC}    $INSTALL_HOME"
    echo -e "${GREEN}Bench:${NC}   $BENCH_NAME"
    echo -e "${GREEN}Site:${NC}    $SITE_NAME"
    echo -e "${GREEN}Version:${NC} $BENCH_VERSION"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════${NC}"
    
    read -p "Continue? (yes/no): " confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    
    [[ "$confirm" != "yes" && "$confirm" != "y" ]] && echo -e "${RED}Cancelled${NC}" && exit 0
}

select_version() {
    echo -e "${YELLOW}Select ERPNext version:${NC}"
    versions=("Version 13" "Version 14" "Version 15" "Version 16" "Develop")
    select ver in "${versions[@]}"; do
        case $REPLY in
            1) BENCH_VERSION="version-13"; break;;
            2) BENCH_VERSION="version-14"; break;;
            3) BENCH_VERSION="version-15"; break;;
            4) BENCH_VERSION="version-16"; break;;
            5) 
                echo -e "${RED}⚠️  WARNING: Develop is unstable!${NC}"
                read -p "Continue? (yes/no): " dev_confirm
                [[ "$(echo $dev_confirm | tr '[:upper:]' '[:lower:]')" =~ ^(yes|y)$ ]] && BENCH_VERSION="develop" && break
                ;;
            *) echo -e "${RED}Invalid${NC}";;
        esac
    done
    echo -e "${GREEN}Selected: $ver${NC}"
}

verify_compatibility() {
    local os_name=$(lsb_release -si)
    local os_version=$(lsb_release -rs)
    
    if [[ "$BENCH_VERSION" =~ ^(version-15|version-16|develop)$ ]]; then
        if [[ "$os_name" == "Ubuntu" && "$os_version" < "22.04" ]]; then
            echo -e "${RED}Ubuntu 22.04+ required for $BENCH_VERSION${NC}"
            exit 1
        elif [[ "$os_name" == "Debian" && "$os_version" < "12" ]]; then
            echo -e "${RED}Debian 12+ required for $BENCH_VERSION${NC}"
            exit 1
        fi
    fi
}

# =============================================================================
# INSTALLATION FUNCTIONS - FIXED
# =============================================================================

install_system_packages() {
    echo -e "${YELLOW}Updating system...${NC}"
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common git curl whiptail cron
    echo -e "${GREEN}✓ System updated${NC}"
}

install_python() {
    echo -e "${YELLOW}Installing Python...${NC}"
    
    local required_minor=10
    local required_full="3.10.11"
    
    [[ "$BENCH_VERSION" == "version-16" ]] && required_minor=11 && required_full="3.11.6"
    
    local current_minor=$(python3 --version 2>&1 | awk '{print $2}' | cut -d'.' -f2)
    
    if [[ -z "$current_minor" || "$current_minor" -lt "$required_minor" ]]; then
        echo -e "${YELLOW}Installing Python 3.$required_minor...${NC}"
        
        sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
            libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget libbz2-dev
        
        wget -q https://www.python.org/ftp/python/${required_full}/Python-${required_full}.tgz
        tar -xf Python-${required_full}.tgz
        cd Python-${required_full}
        ./configure --prefix=/usr/local --enable-optimizations --enable-shared \
            LDFLAGS="-Wl,-rpath /usr/local/lib" --quiet
        make -j $(nproc) > /dev/null
        sudo make altinstall > /dev/null
        cd .. && rm -rf Python-${required_full}*
        
        echo -e "${GREEN}✓ Python 3.$required_minor installed${NC}"
    fi
    
    sudo apt install -y git python3-dev python3-setuptools python3-venv python3-pip redis-server
}

install_wkhtmltopdf() {
    echo -e "${YELLOW}Installing wkhtmltopdf...${NC}"
    
    local arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] && arch="amd64"
    [[ "$arch" == "aarch64" ]] && arch="arm64"
    
    sudo apt install -y fontconfig libxrender1 xfonts-75dpi xfonts-base
    wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_${arch}.deb
    sudo dpkg -i wkhtmltox_*.deb 2>/dev/null || true
    sudo cp /usr/local/bin/wkhtmlto* /usr/bin/ 2>/dev/null || true
    sudo chmod a+x /usr/bin/wk*
    rm wkhtmltox_*.deb
    sudo apt --fix-broken install -y
    
    echo -e "${GREEN}✓ wkhtmltopdf installed${NC}"
}

install_mariadb() {
    echo -e "${YELLOW}Installing MariaDB...${NC}"
    sudo apt install -y mariadb-server mariadb-client pkg-config default-libmysqlclient-dev
    
    if [ ! -f ~/.mysql_configured ]; then
        sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$SQL_PASSWORD';" 2>/dev/null || true
        sudo mysql -u root -p"$SQL_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null
        sudo mysql -u root -p"$SQL_PASSWORD" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null
        sudo mysql -u root -p"$SQL_PASSWORD" -e "FLUSH PRIVILEGES;" 2>/dev/null
        
        sudo tee -a /etc/mysql/my.cnf > /dev/null << 'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF
        
        sudo service mysql restart
        touch ~/.mysql_configured
    fi
    
    echo -e "${GREEN}✓ MariaDB configured${NC}"
}

install_node() {
    echo -e "${YELLOW}Installing Node.js via NVM...${NC}"
    
    sudo -u "$INSTALL_USER" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash'
    
    local nvm_init='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    
    sudo -u "$INSTALL_USER" bash -c "echo '$nvm_init' >> ~/.bashrc"
    
    local node_ver=16
    [[ "$BENCH_VERSION" == "version-16" ]] && node_ver=20
    [[ "$BENCH_VERSION" =~ ^(version-15|develop)$ ]] && node_ver=18
    
    sudo -u "$INSTALL_USER" bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
        nvm install $node_ver
        nvm alias default $node_ver
    "
    
    echo -e "${GREEN}✓ Node.js v$node_ver installed${NC}"
}

setup_supervisor() {
    echo -e "${YELLOW}Setting up Supervisor...${NC}"
    
    sudo apt install -y supervisor
    
    [ ! -f /etc/supervisor/supervisord.conf ] && sudo tee /etc/supervisor/supervisord.conf > /dev/null << 'EOF'
[unix_http_server]
file=/var/run/supervisor.sock
[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
[include]
files = /etc/supervisor/conf.d/*.conf
EOF
    
    sudo mkdir -p /etc/supervisor/conf.d
    sudo systemctl enable supervisor
    sudo systemctl restart supervisor
    
    echo -e "${GREEN}✓ Supervisor ready${NC}"
}

install_bench() {
    echo -e "${YELLOW}Installing frappe-bench (with network retry)...${NC}"
    
    configure_pip_for_network
    
    sudo apt install -y python3-pip
    
    local max_attempts=5
    local attempt=1
    local success=false
    
    while [ $attempt -le $max_attempts ]; do
        echo -e "${LIGHT_BLUE}Attempt $attempt/$max_attempts...${NC}"
        
        if sudo -H pip3 install --upgrade --timeout=300 --retries=10 frappe-bench 2>&1 | tee /tmp/pip.log; then
            success=true
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            echo -e "${YELLOW}Trying GitHub installation...${NC}"
            if sudo -H pip3 install --timeout=300 git+https://github.com/frappe/bench.git; then
                success=true
                break
            fi
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    [ "$success" = false ] && echo -e "${RED}Failed to install bench${NC}" && exit 1
    
    echo -e "${GREEN}✓ frappe-bench installed${NC}"
    
    echo -e "${YELLOW}Initializing bench...${NC}"
    sudo -u "$INSTALL_USER" bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
        nvm use default
        cd '$INSTALL_HOME'
        bench init '$BENCH_NAME' --frappe-branch '$BENCH_VERSION' --verbose
    "
    
    echo -e "${GREEN}✓ Bench initialized${NC}"
}

create_site() {
    echo -e "${YELLOW}Creating site...${NC}"
    
    sudo chmod -R o+rx "$INSTALL_HOME"
    
    sudo -u "$INSTALL_USER" bash -c "
        cd '$INSTALL_HOME/$BENCH_NAME'
        bench new-site '$SITE_NAME' \
            --db-root-username root \
            --db-root-password '$SQL_PASSWORD' \
            --admin-password '$ADMIN_PASSWORD'
    "
    
    echo -e "${GREEN}✓ Site created${NC}"
}

install_erpnext() {
    echo -e "${YELLOW}Installing ERPNext...${NC}"
    
    sudo -u "$INSTALL_USER" bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
        nvm use default
        cd '$INSTALL_HOME/$BENCH_NAME'
        bench get-app --branch '$BENCH_VERSION' erpnext
        bench --site '$SITE_NAME' install-app erpnext
    "
    
    echo -e "${GREEN}✓ ERPNext installed${NC}"
}

setup_production() {
    echo -e "${YELLOW}Setting up production...${NC}"
    
    sudo apt install -y nginx
    
    sudo -u "$INSTALL_USER" bash -c "
        cd '$INSTALL_HOME/$BENCH_NAME'
        yes | sudo bench setup production '$INSTALL_USER'
        bench --site '$SITE_NAME' scheduler enable
    "
    
    sudo supervisorctl reread
    sudo supervisorctl update
    sudo systemctl reload nginx
    
    echo -e "${GREEN}✓ Production ready${NC}"
}

setup_ssl() {
    [[ -z "$EMAIL_ADDRESS" ]] && return
    
    echo -e "${YELLOW}Installing SSL...${NC}"
    
    if ! command -v certbot &>/dev/null; then
        sudo apt install -y snapd
        sudo snap install core
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
    fi
    
    sudo certbot --nginx --non-interactive --agree-tos --email "$EMAIL_ADDRESS" -d "$SITE_NAME" || \
        echo -e "${YELLOW}SSL failed. Install manually: sudo certbot --nginx -d $SITE_NAME${NC}"
}

# =============================================================================
# MAIN INSTALLATION
# =============================================================================

main_menu() {
    clear
    echo -e "${LIGHT_BLUE}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${LIGHT_BLUE}║   ERPNext Universal Installation Manager ║${NC}"
    echo -e "${LIGHT_BLUE}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Single Installation ${LIGHT_BLUE}(Production)${NC}"
    echo -e "${YELLOW}2.${NC} Multiple Installations ${RED}(Development)${NC}"
    echo -e "${RED}3.${NC} Exit"
    echo ""
    
    read -p "Choice (1-3): " mode
    
    case $mode in
        1|2)
            if [ "$mode" = "2" ]; then
                echo ""
                echo -e "${RED}⚠️  Multiple installations can cause conflicts!${NC}"
                echo -e "${YELLOW}Use different bench folders for each version${NC}"
                echo ""
                read -p "Continue? (yes/no): " multi_confirm
                [[ "$(echo $multi_confirm | tr '[:upper:]' '[:lower:]')" != "yes" ]] && exit 0
            fi
            
            run_installation
            ;;
        3)
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

run_installation() {
    select_version
    collect_info
    show_summary
    check_existing_installations
    verify_compatibility
    
    echo -e "${GREEN}Starting installation...${NC}"
    
    install_system_packages
    install_python
    install_wkhtmltopdf
    install_mariadb
    install_node
    setup_supervisor
    install_bench
    create_site
    install_erpnext
    setup_production
    setup_ssl
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Installation Completed Successfully!  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Access:${NC} http://$server_ip"
    echo -e "${YELLOW}Site:${NC} $SITE_NAME"
    echo -e "${YELLOW}User:${NC} Administrator"
    echo ""
    echo -e "${LIGHT_BLUE}Commands:${NC}"
    echo -e "  ${GREEN}cd $INSTALL_HOME/$BENCH_NAME && bench start${NC}"
    echo ""
}

# Run
main_menu