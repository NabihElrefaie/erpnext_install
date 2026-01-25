#!/usr/bin/env bash

handle_error() {
    local line=$1
    local exit_code=$?
    echo "An error occurred on line $line with exit status $exit_code"
    exit $exit_code
}

trap 'handle_error $LINENO' ERR
set -e

server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || hostname 2>/dev/null || echo "localhost")

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

SUPPORTED_DISTRIBUTIONS=("Ubuntu" "Debian")
SUPPORTED_VERSIONS=("24.04" "23.04" "22.04" "20.04" "12" "11" "10" "9" "8")

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
NODE_VERSION=""

check_os() {
    local os_name=$(lsb_release -is 2>/dev/null)
    local os_version=$(lsb_release -rs 2>/dev/null)
    local os_supported=false
    local version_supported=false

    for i in "${SUPPORTED_DISTRIBUTIONS[@]}"; do
        if [[ "$i" = "$os_name" ]]; then
            os_supported=true
            break
        fi
    done

    for i in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ "$i" = "$os_version" ]]; then
            version_supported=true
            break
        fi
    done

    if [[ "$os_supported" = false ]] || [[ "$version_supported" = false ]]; then
        echo -e "${RED}This script is not compatible with your operating system or its version.${NC}"
        exit 1
    fi
}

check_os

OS="$(uname)"
case $OS in
  'Linux')
    OS='Linux'
    if [ -f /etc/redhat-release ] ; then
      DISTRO='CentOS'
    elif [ -f /etc/debian_version ] ; then
      if command -v lsb_release &> /dev/null; then
        if [ "$(lsb_release -si)" == "Ubuntu" ]; then
          DISTRO='Ubuntu'
        else
          DISTRO='Debian'
        fi
      elif [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
          DISTRO='Ubuntu'
        else
          DISTRO='Debian'
        fi
      fi
    fi
    ;;
  *) ;;
esac

ask_twice() {
    local prompt="$1"
    local secret="$2"
    local val1 val2

    while true; do
        if [ "$secret" = "true" ]; then
            read -rsp "$prompt: " val1
            echo >&2
        else
            read -rp "$prompt: " val1
            echo >&2
        fi

        if [ "$secret" = "true" ]; then
            read -rsp "Confirm password: " val2
            echo >&2
        else
            read -rp "Confirm password: " val2
            echo >&2
        fi

        if [ "$val1" = "$val2" ]; then
            printf "${GREEN}Password confirmed${NC}\n" >&2
            echo "$val1"
            break
        else
            printf "${RED}Inputs do not match. Please try again${NC}\n" >&2
            echo -e "\n"
        fi
    done
}

create_user_if_not_exists() {
    local user="$1"
    
    if ! id "$user" &>/dev/null; then
        echo -e "${YELLOW}Creating new user: $user...${NC}"
        sudo adduser --disabled-password --gecos "" "$user" > /dev/null 2>&1
        sudo usermod -aG sudo "$user" > /dev/null 2>&1
        echo "$user:$DEFAULT_PASSWORD" | sudo chpasswd > /dev/null 2>&1
        
        # إعداد مجلد .ssh لأذونات صحيحة
        sudo -u "$user" mkdir -p "/home/$user/.ssh"
        sudo chmod 700 "/home/$user/.ssh"
        echo -e "${GREEN}✓ User $user created successfully${NC}"
        echo -e "${YELLOW}Default password: $DEFAULT_PASSWORD${NC}"
        echo -e "${YELLOW}Please change password after first login${NC}"
    else
        echo -e "${GREEN}User $user already exists${NC}"
    fi
}

select_or_create_user() {
    echo -e "${YELLOW}Select installation user:${NC}"
    echo "1. Use current user ($(whoami))"
    echo "2. Create new user"
    echo "3. Select existing user"
    
    read -p "Enter choice (1-3): " user_choice
    
    case $user_choice in
        1)
            INSTALL_USER=$(whoami)
            if [ "$INSTALL_USER" = "root" ]; then
                echo -e "${RED}Cannot install as root user. Please select another user.${NC}"
                return 1
            fi
            INSTALL_HOME=$HOME
            echo -e "${GREEN}Using current user: $INSTALL_USER${NC}"
            ;;
        2)
            read -p "Enter new username: " new_user
            if [[ -z "$new_user" ]]; then
                echo -e "${RED}Username cannot be empty${NC}"
                return 1
            fi
            create_user_if_not_exists "$new_user"
            INSTALL_USER="$new_user"
            INSTALL_HOME="/home/$new_user"
            ;;
        3)
            read -p "Enter existing username: " existing_user
            if ! id "$existing_user" &>/dev/null; then
                echo -e "${RED}User $existing_user does not exist.${NC}"
                return 1
            fi
            INSTALL_USER="$existing_user"
            INSTALL_HOME="/home/$existing_user"
            echo -e "${GREEN}Using existing user: $INSTALL_USER${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice. Using current user.${NC}"
            INSTALL_USER=$(whoami)
            INSTALL_HOME=$HOME
            ;;
    esac
    
    # إعداد أذونات sudo بدون كلمة مرور للمستخدم
    if ! sudo grep -q "^$INSTALL_USER.*NOPASSWD" /etc/sudoers; then
        echo "$INSTALL_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/"$INSTALL_USER" > /dev/null
        sudo chmod 440 /etc/sudoers.d/"$INSTALL_USER"
    fi
    
    return 0
}

collect_pre_install_info() {
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}         PRE-INSTALLATION INFORMATION COLLECTION          ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Select or create user for installation
    echo -e "${YELLOW}Step 1: Select installation user${NC}"
    while ! select_or_create_user; do
        echo -e "${RED}Please try again${NC}"
    done
    
    echo -e "${GREEN}✓ User selected: $INSTALL_USER${NC}"
    echo -e "${GREEN}✓ Home directory: $INSTALL_HOME${NC}"
    echo ""
    
    # Collect bench name
    echo -e "${YELLOW}Step 2: Enter bench folder name${NC}"
    read -p "Enter bench folder name (default: frappe-bench): " BENCH_NAME
    BENCH_NAME=${BENCH_NAME:-frappe-bench}
    echo -e "${GREEN}✓ Bench folder: $BENCH_NAME${NC}"
    echo ""
    
    # Collect site name
    echo -e "${YELLOW}Step 3: Enter site name${NC}"
    read -p "Enter site name (FQDN if planning SSL later): " SITE_NAME
    while [[ -z "$SITE_NAME" ]]; do
        echo -e "${RED}Site name cannot be empty. Please enter a valid site name.${NC}"
        read -p "Enter site name (FQDN if planning SSL later): " SITE_NAME
    done
    echo -e "${GREEN}✓ Site name: $SITE_NAME${NC}"
    echo ""
    
    # Collect SQL password
    echo -e "${YELLOW}Step 4: Set SQL root password${NC}"
    SQL_PASSWORD=$(ask_twice "What is your required SQL root password" "true")
    echo -e "${GREEN}✓ SQL password set${NC}"
    echo ""
    
    # Collect admin password
    echo -e "${YELLOW}Step 5: Set Administrator password${NC}"
    ADMIN_PASSWORD=$(ask_twice "Enter the Administrator password" "true")
    echo -e "${GREEN}✓ Admin password set${NC}"
    echo ""
    
    # Collect email for SSL (optional)
    echo -e "${YELLOW}Step 6: Email address (optional, for SSL certificates)${NC}"
    read -p "Enter email address for SSL (press Enter to skip): " EMAIL_ADDRESS
    if [[ -n "$EMAIL_ADDRESS" ]]; then
        echo -e "${GREEN}✓ Email: $EMAIL_ADDRESS${NC}"
    else
        echo -e "${YELLOW}ℹ Email skipped (can add later)${NC}"
    fi
}

show_install_summary() {
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}             INSTALLATION SUMMARY                       ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}User:${NC}         $INSTALL_USER"
    echo -e "${GREEN}Home:${NC}         $INSTALL_HOME"
    echo -e "${GREEN}Bench:${NC}        $BENCH_NAME"
    echo -e "${GREEN}Site:${NC}         $SITE_NAME"
    echo -e "${GREEN}SQL Password:${NC}  ✓ Set"
    echo -e "${GREEN}Admin Password:${NC} ✓ Set"
    if [[ -n "$EMAIL_ADDRESS" ]]; then
        echo -e "${GREEN}Email:${NC}        $EMAIL_ADDRESS"
    else
        echo -e "${GREEN}Email:${NC}        Not set"
    fi
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "Continue with installation? (yes/no): " confirm_install
    confirm_install=$(echo "$confirm_install" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$confirm_install" != "yes" && "$confirm_install" != "y" ]]; then
        echo -e "${RED}Installation cancelled by user.${NC}"
        exit 0
    fi
    
    echo -e "${GREEN}✓ Starting installation with collected information...${NC}"
    echo ""
}

select_version() {
    echo -e "${YELLOW}Please enter the number of the corresponding ERPNext version you wish to install:${NC}"
    
    versions=("Version 13" "Version 14" "Version 15" "Version 16" "Develop")
    select version_choice in "${versions[@]}"; do
        case $REPLY in
            1) 
                BENCH_VERSION="version-13"
                NODE_VERSION="16"
                break
                ;;
            2) 
                BENCH_VERSION="version-14"
                NODE_VERSION="16"
                break
                ;;
            3) 
                BENCH_VERSION="version-15"
                NODE_VERSION="18"
                break
                ;;
            4) 
                BENCH_VERSION="version-16"
                NODE_VERSION="24"
                break
                ;;
            5) 
                BENCH_VERSION="develop"
                NODE_VERSION="18"
                echo ""
                echo -e "${RED}⚠️  WARNING: DEVELOP VERSION ⚠️${NC}"
                echo ""
                echo -e "${YELLOW}The develop branch contains bleeding-edge code that:${NC}"
                echo -e "${RED}• Changes daily and may be unstable${NC}"
                echo -e "${RED}• Can cause data corruption or system crashes${NC}"
                echo -e "${RED}• Is NOT suitable for production or important data${NC}"
                echo -e "${RED}• Has limited community support${NC}"
                echo ""
                echo -e "${GREEN}Recommended for: Experienced developers testing new features${NC}"
                echo -e "${GREEN}Better alternatives: Version 15 (stable) or Version 14 (proven)${NC}"
                echo ""
                read -p "Do you understand the risks and want to continue? (yes/no): " develop_confirm
                develop_confirm=$(echo "$develop_confirm" | tr '[:upper:]' '[:lower:]')
               
                if [[ "$develop_confirm" != "yes" && "$develop_confirm" != "y" ]]; then
                    echo -e "${GREEN}Good choice! Please select a stable version.${NC}"
                    continue
                else
                    echo -e "${YELLOW}Proceeding with develop branch installation...${NC}"
                fi
                break
                ;;
            *) echo -e "${RED}Invalid option. Please select a valid version.${NC}";;
        esac
    done

    echo -e "${GREEN}You have selected $version_choice for installation.${NC}"
    echo -e "${LIGHT_BLUE}Node.js version: $NODE_VERSION${NC}"
}

verify_version_compatibility() {
    local os_name=$(lsb_release -si)
    local os_version=$(lsb_release -rs)
    
    if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
        if [[ "$os_name" != "Ubuntu" && "$os_name" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$os_name" == "Ubuntu" && "$os_version" < "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$os_name" == "Debian" && "$os_version" < "12" ]]; then
            echo -e "${RED}Your Debian version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        fi
    fi

    if [[ "$BENCH_VERSION" != "version-15" && "$BENCH_VERSION" != "version-16" && "$BENCH_VERSION" != "develop" ]]; then
        if [[ "$os_name" != "Ubuntu" && "$os_name" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for this version.${NC}"
            exit 1
        elif [[ "$os_name" == "Ubuntu" && "$os_version" > "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is not supported for this version.${NC}"
            echo -e "${YELLOW}ERPNext v13/v14 only support Ubuntu up to 22.04. Please use ERPNext v15/v16 for Ubuntu 24.04.${NC}"
            exit 1
        elif [[ "$os_name" == "Debian" && "$os_version" > "11" ]]; then
            echo -e "${YELLOW}Warning: Your Debian version is above the tested range for this version, but we'll continue.${NC}"
            sleep 2
        fi
    fi
}

install_system_packages() {
    echo -e "${YELLOW}Updating system packages...${NC}"
    sleep 2
    sudo apt update
    sudo apt upgrade -y
    echo -e "${GREEN}System packages updated.${NC}"
    sleep 2

    echo -e "${YELLOW}Installing preliminary package requirements${NC}"
    sleep 3
    sudo apt install software-properties-common git curl wget whiptail cron -y
}

install_yarn_for_user() {
    local user="$1"
    echo -e "${YELLOW}Installing Yarn for user: $user...${NC}"
    
    # تثبيت Yarn classic (الإصدار المستقر)
    sudo -u "$user" bash -c '
        # تنظيف أي تثبيت سابق
        rm -rf ~/.yarn ~/.config/yarn
        
        # تثبيت Yarn باستخدام npm
        if command -v npm >/dev/null 2>&1; then
            npm install -g yarn@1.22.19
        fi
        
        # إذا فشل npm، نقوم بالتثبيت المباشر
        if ! command -v yarn >/dev/null 2>&1; then
            curl -o- -L https://yarnpkg.com/install.sh | bash -s -- --version 1.22.19
            export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"
        fi
        
        # إضافة Yarn إلى PATH في ملفات التهيئة
        if [[ ":$PATH:" != *":$HOME/.yarn/bin:"* ]]; then
            echo "export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"" >> ~/.bashrc
            echo "export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"" >> ~/.profile
        fi
    '
    
    # تأكيد التثبيت
    if sudo -u "$user" bash -c 'command -v yarn' &>/dev/null; then
        local yarn_version=$(sudo -u "$user" bash -c 'yarn --version 2>/dev/null || echo "not found"')
        echo -e "${GREEN}✓ Yarn installed for $user: $yarn_version${NC}"
    else
        echo -e "${YELLOW}⚠ Yarn installation may have issues for $user${NC}"
    fi
}

fix_supervisor_for_user() {
    local user="$1"
    echo -e "${YELLOW}Configuring Supervisor for user: $user...${NC}"
    
    # تثبيت Supervisor إذا لم يكن مثبتاً
    if ! dpkg -l | grep -q supervisor; then
        sudo apt install -y supervisor
    fi
    
    # إعداد Supervisor للعمل مع المستخدم
    sudo mkdir -p /etc/supervisor/conf.d
    sudo chmod 755 /etc/supervisor
    
    # إعداد ملف Supervisor الأساسي
    if [ ! -f /etc/supervisor/supervisord.conf ]; then
        sudo tee /etc/supervisor/supervisord.conf > /dev/null <<EOF
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0770
chown=root:root

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor
minfds=1024
minprocs=200
user=root

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
EOF
    fi
    
    # تأمين الملفات
    sudo chmod 644 /etc/supervisor/supervisord.conf
    sudo chown root:root /etc/supervisor/supervisord.conf
    
    # إعادة تشغيل Supervisor
    sudo systemctl enable supervisor
    sudo systemctl restart supervisor
    
    echo -e "${GREEN}✓ Supervisor configured for $user${NC}"
}

install_python() {
    echo -e "${YELLOW}Installing Python and dependencies...${NC}"
    sleep 2

    local py_version=$(python3 --version 2>&1 | awk '{print $2}')
    local py_major=$(echo "$py_version" | cut -d '.' -f 1)
    local py_minor=$(echo "$py_version" | cut -d '.' -f 2)

    local required_python_minor=10
    local required_python_label="3.10"
    local required_python_full="3.10.12"

    if [[ "$BENCH_VERSION" == "version-16" ]]; then
        required_python_minor=14
        required_python_label="3.14"
        required_python_full="3.14.0"
    fi

    if [[ -z "$py_version" ]] || [[ "$py_major" -lt 3 ]] || [[ "$py_major" -eq 3 && "$py_minor" -lt "$required_python_minor" ]]; then
        echo -e "${LIGHT_BLUE}Installing Python ${required_python_label}+...${NC}"
        sleep 2

        sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
            libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget libbz2-dev
        
        # تنزيل وتثبيت Python
        cd /tmp
        wget https://www.python.org/ftp/python/${required_python_full}/Python-${required_python_full}.tgz
        tar -xf Python-${required_python_full}.tgz
        cd Python-${required_python_full}
        ./configure --prefix=/usr/local --enable-optimizations --enable-shared LDFLAGS="-Wl,-rpath /usr/local/lib"
        make -j "$(nproc)"
        sudo make altinstall
        cd ..
        sudo rm -rf Python-${required_python_full}
        sudo rm Python-${required_python_full}.tgz
        
        # تثبيت pip
        if [ -f "/usr/local/bin/pip3.${required_python_minor}" ]; then
            sudo /usr/local/bin/pip3."${required_python_minor}" install --upgrade pip
        fi
        
        echo -e "${GREEN}Python${required_python_label} installation successful!${NC}"
        sleep 2
    else
        echo -e "${GREEN}✓ Python ${py_version} already meets requirements${NC}"
    fi

    echo -e "\n${YELLOW}Installing additional Python packages and Redis Server${NC}"
    sleep 2
    sudo apt install -y git python3-dev python3-setuptools python3-venv python3-pip redis-server
}

install_wkhtmltopdf() {
    echo -e "${YELLOW}Installing wkhtmltopdf...${NC}"
    sleep 2
    
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) 
            echo -e "${YELLOW}Unsupported architecture: $arch, trying generic install${NC}"
            arch="amd64" 
            ;;
    esac

    sudo apt install -y fontconfig libxrender1 xfonts-75dpi xfonts-base libfontconfig xvfb

    # محاولة تنزيل وتثبيت wkhtmltopdf
    cd /tmp
    if wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_"$arch".deb 2>/dev/null; then
        sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_"$arch".deb || true
        sudo apt --fix-broken install -y
        sudo cp /usr/local/bin/wkhtmlto* /usr/bin/ 2>/dev/null || true
        sudo chmod a+x /usr/bin/wk* 2>/dev/null || true
        rm -f wkhtmltox_0.12.6.1-2.jammy_"$arch".deb
    else
        echo -e "${YELLOW}Using apt version of wkhtmltopdf${NC}"
        sudo apt install -y wkhtmltopdf
    fi

    echo -e "${GREEN}✓ wkhtmltopdf installed${NC}"
    sleep 1
}

install_mariadb() {
    echo -e "${YELLOW}Installing MariaDB...${NC}"
    sleep 2
    
    # تثبيت MariaDB فقط
    sudo apt install -y mariadb-server mariadb-client
    
    echo -e "${YELLOW}Installing development libraries...${NC}"
    
    # حل مشكلة التعارض بين الحزم
    # نستخدم إما libmariadb-dev أو libmysqlclient-dev حسب التوفر
    if apt-cache show libmariadb-dev >/dev/null 2>&1; then
        echo -e "${LIGHT_BLUE}Installing libmariadb-dev...${NC}"
        sudo apt install -y libmariadb-dev pkg-config
    elif apt-cache show libmysqlclient-dev >/dev/null 2>&1; then
        echo -e "${LIGHT_BLUE}Installing libmysqlclient-dev...${NC}"
        sudo apt install -y libmysqlclient-dev pkg-config
    else
        echo -e "${YELLOW}⚠ Neither libmariadb-dev nor libmysqlclient-dev found, trying default...${NC}"
        sudo apt install -y default-libmysqlclient-dev pkg-config
    fi
    
    echo -e "${GREEN}✓ MariaDB installed successfully${NC}"
    sleep 2

    # إعداد MariaDB
    echo -e "${YELLOW}Configuring MariaDB security...${NC}"
    sleep 2

    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$SQL_PASSWORD';" 2>/dev/null || true
    sudo mysql -u root -p"$SQL_PASSWORD" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$SQL_PASSWORD';" 2>/dev/null || true
    sudo mysql -u root -p"$SQL_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    sudo mysql -u root -p"$SQL_PASSWORD" -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
    sudo mysql -u root -p"$SQL_PASSWORD" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    # إعدادات UTF8MB4
    sudo tee /etc/mysql/mariadb.conf.d/99-erpnext.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4

[client]
default-character-set = utf8mb4
EOF

    sudo systemctl restart mariadb
    echo -e "${GREEN}✓ MariaDB configured${NC}"
}

install_node_for_user() {
    local user="$1"
    local node_version="$2"
    
    echo -e "${YELLOW}Installing Node.js $node_version for user: $user...${NC}"
    
    # تثبيت NVM للمستخدم
    sudo -u "$user" bash -c '
        # تنظيف أي تثبيت سابق
        rm -rf ~/.nvm ~/.npm
        
        # تثبيت NVM
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
        
        # تهيئة NVM في الجلسة الحالية
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        
        # إضافة NVM إلى ملفات التهيئة
        if ! grep -q "NVM_DIR" ~/.bashrc; then
            echo "export NVM_DIR=\"\$HOME/.nvm\"" >> ~/.bashrc
            echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"" >> ~/.bashrc
            echo "[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"" >> ~/.bashrc
        fi
        
        if ! grep -q "NVM_DIR" ~/.profile; then
            echo "export NVM_DIR=\"\$HOME/.nvm\"" >> ~/.profile
            echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"" >> ~/.profile
        fi
    '
    
    # تثبيت Node.js الإصدار المطلوب
    sudo -u "$user" bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
        
        nvm install $node_version
        nvm use $node_version
        nvm alias default $node_version
        
        # تثبيت npm global packages
        npm install -g npm@latest
    "
    
    echo -e "${GREEN}✓ Node.js $node_version installed for $user${NC}"
}

install_bench_for_user() {
    local user="$1"
    local home="$2"
    
    echo -e "${YELLOW}Installing bench for user: $user...${NC}"
    
    # حل مشكلة EXTERNALLY-MANAGED في Python
    externally_managed_file=$(find /usr/lib/python3.*/EXTERNALLY-MANAGED 2>/dev/null | head -1)
    if [[ -n "$externally_managed_file" ]]; then
        sudo python3 -m pip config --global set global.break-system-packages true
    fi
    
    # تثبيت frappe-bench
    sudo pip3 install frappe-bench
    
    # تهيئة bench للمستخدم
    sudo -u "$user" bash -c "
        cd '$home'
        
        # تهيئة Node.js وPython
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
        nvm use default
        
        # تهيئة Yarn
        if [[ -f \"\$HOME/.yarn/bin/yarn\" ]]; then
            export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"
        fi
        
        # إنشاء bench
        bench init '$BENCH_NAME' --version '$BENCH_VERSION' --verbose --skip-redis-config
    "
    
    echo -e "${GREEN}✓ Bench installed for $user${NC}"
}

setup_redis_for_bench() {
    local user="$1"
    local home="$2"
    
    echo -e "${YELLOW}Setting up Redis for bench...${NC}"
    
    # إيقاف أي مثيلات Redis قيد التشغيل
    sudo systemctl stop redis-server 2>/dev/null || true
    sudo pkill -f "redis-server" 2>/dev/null || true
    
    if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
        # إصدارات جديدة تحتاج إلى 3 مثيلات Redis
        echo -e "${LIGHT_BLUE}Starting multiple Redis instances for $BENCH_VERSION...${NC}"
        
        # بدء مثيلات Redis
        sudo -u redis redis-server --port 11000 --daemonize yes --bind 127.0.0.1 --save "" --appendonly no
        sudo -u redis redis-server --port 12000 --daemonize yes --bind 127.0.0.1 --save "" --appendonly no
        sudo -u redis redis-server --port 13000 --daemonize yes --bind 127.0.0.1 --save "" --appendonly no
        
        # التحقق من التشغيل
        sleep 2
        if redis-cli -p 11000 ping | grep -q "PONG"; then
            echo -e "${GREEN}✓ Redis cache (11000) started${NC}"
        fi
        if redis-cli -p 12000 ping | grep -q "PONG"; then
            echo -e "${GREEN}✓ Redis queue (12000) started${NC}"
        fi
        if redis-cli -p 13000 ping | grep -q "PONG"; then
            echo -e "${GREEN}✓ Redis socketio (13000) started${NC}"
        fi
    else
        # إصدارات أقدم تستخدم redis-server الافتراضي
        echo -e "${LIGHT_BLUE}Starting default Redis server...${NC}"
        sudo systemctl start redis-server
        sudo systemctl enable redis-server
        if sudo systemctl is-active --quiet redis-server; then
            echo -e "${GREEN}✓ Redis server started${NC}"
        fi
    fi
    
    # تكوين Redis في bench
    sudo -u "$user" bash -c "
        cd '$home/$BENCH_NAME'
        bench setup redis --yes
    "
}

create_site_for_user() {
    local user="$1"
    local home="$2"
    
    echo -e "${YELLOW}Creating site: $SITE_NAME...${NC}"
    
    sudo -u "$user" bash -c "
        cd '$home/$BENCH_NAME'
        
        # تهيئة البيئة
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
        nvm use default
        
        if [[ -f \"\$HOME/.yarn/bin/yarn\" ]]; then
            export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"
        fi
        
        # إنشاء الموقع
        bench new-site '$SITE_NAME' \
            --db-root-username root \
            --db-root-password '$SQL_PASSWORD' \
            --admin-password '$ADMIN_PASSWORD' \
            --verbose
    "
    
    echo -e "${GREEN}✓ Site created successfully${NC}"
}

install_erpnext_for_user() {
    local user="$1"
    local home="$2"
    
    echo -e "${YELLOW}Installing ERPNext...${NC}"
    
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo -e "${LIGHT_BLUE}Attempt $((retry_count + 1))...${NC}"
        
        if sudo -u "$user" bash -c "
            cd '$home/$BENCH_NAME'
            
            export NVM_DIR=\"\$HOME/.nvm\"
            [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
            [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
            nvm use default
            
            if [[ -f \"\$HOME/.yarn/bin/yarn\" ]]; then
                export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"
            fi
            
            # تحميل ERPNext
            bench get-app erpnext --branch '$BENCH_VERSION' --skip-assets --verbose
            
            # تثبيت ERPNext
            bench --site '$SITE_NAME' install-app erpnext --verbose
        "; then
            echo -e "${GREEN}✓ ERPNext installed successfully${NC}"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}Retrying in 5 seconds...${NC}"
            sleep 5
        fi
    done
    
    echo -e "${RED}✗ Failed to install ERPNext after $max_retries attempts${NC}"
    echo -e "${YELLOW}Continuing with setup...${NC}"
    return 1
}

setup_production_for_user() {
    local user="$1"
    local home="$2"
    
    echo -e "${YELLOW}Setting up production environment...${NC}"
    
    # تثبيت nginx إذا لم يكن مثبتاً
    if ! dpkg -l | grep -q nginx; then
        sudo apt install -y nginx
    fi
    
    # تكوين production
    sudo -u "$user" bash -c "
        cd '$home/$BENCH_NAME'
        
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
        nvm use default
        
        if [[ -f \"\$HOME/.yarn/bin/yarn\" ]]; then
            export PATH=\"\$HOME/.yarn/bin:\$HOME/.config/yarn/global/node_modules/.bin:\$PATH\"
        fi
        
        # إعداد production
        yes | bench setup production '$user' --yes
    "
    
    # إعداد Supervisor
    if [ -f "$home/$BENCH_NAME/config/supervisor.conf" ]; then
        sudo cp "$home/$BENCH_NAME/config/supervisor.conf" /etc/supervisor/conf.d/"$SITE_NAME".conf
        sudo supervisorctl reread
        sudo supervisorctl update
    fi
    
    # تمكين Scheduler
    sudo -u "$user" bash -c "
        cd '$home/$BENCH_NAME'
        bench --site '$SITE_NAME' scheduler enable || true
        bench --site '$SITE_NAME' scheduler resume || true
    "
    
    # SocketIO و Redis للإصدارات الجديدة
    if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
        sudo -u "$user" bash -c "
            cd '$home/$BENCH_NAME'
            bench setup socketio --yes || true
            bench setup supervisor --yes || true
        "
    fi
    
    # إعادة تحميل Supervisor
    sudo supervisorctl reread
    sudo supervisorctl update
    
    # بدء الخدمات
    echo -e "${YELLOW}Starting services...${NC}"
    sudo supervisorctl start all 2>/dev/null || true
    
    # بناء الأصول
    sudo -u "$user" bash -c "
        cd '$home/$BENCH_NAME'
        bench build 2>/dev/null || true
    "
    
    echo -e "${GREEN}✓ Production setup completed${NC}"
}

setup_ssl_for_site() {
    if [[ -z "$EMAIL_ADDRESS" ]]; then
        echo -e "${YELLOW}ℹ SSL skipped (no email provided)${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Setting up SSL for $SITE_NAME...${NC}"
    
    # تثبيت Certbot
    if ! command -v certbot >/dev/null 2>&1; then
        sudo apt install -y snapd
        sudo snap install core
        sudo snap refresh core
        sudo snap install --classic certbot
        sudo ln -sf /snap/bin/certbot /usr/bin/certbot
    fi
    
    # الحصول على شهادة SSL
    if sudo certbot --nginx --non-interactive --agree-tos --email "$EMAIL_ADDRESS" -d "$SITE_NAME" 2>/dev/null; then
        echo -e "${GREEN}✓ SSL certificate installed${NC}"
    else
        echo -e "${YELLOW}⚠ SSL installation failed or not needed${NC}"
    fi
}

show_final_summary() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           INSTALLATION COMPLETED SUCCESSFULLY!               ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${LIGHT_BLUE}Installation Details:${NC}"
    echo -e "${GREEN}• User:${NC}             $INSTALL_USER"
    echo -e "${GREEN}• Bench Folder:${NC}     $INSTALL_HOME/$BENCH_NAME"
    echo -e "${GREEN}• Site Name:${NC}        $SITE_NAME"
    echo -e "${GREEN}• ERPNext Version:${NC}  $BENCH_VERSION"
    echo -e "${GREEN}• Node.js Version:${NC}  $NODE_VERSION"
    echo ""
    
    echo -e "${LIGHT_BLUE}Access Information:${NC}"
    echo -e "${GREEN}• Admin URL:${NC}        http://$SITE_NAME"
    if [[ -n "$EMAIL_ADDRESS" ]]; then
        echo -e "${GREEN}• SSL URL:${NC}          https://$SITE_NAME"
    fi
    echo -e "${GREEN}• Server IP:${NC}        $server_ip"
    echo -e "${GREEN}• Admin User:${NC}       Administrator"
    echo -e "${GREEN}• Admin Password:${NC}   [The password you set]"
    echo ""
    
    echo -e "${LIGHT_BLUE}Useful Commands:${NC}"
    echo -e "${YELLOW}  Switch to user:${NC}       sudo su - $INSTALL_USER"
    echo -e "${YELLOW}  Start bench:${NC}          cd $INSTALL_HOME/$BENCH_NAME && bench start"
    echo -e "${YELLOW}  Stop bench:${NC}           cd $INSTALL_HOME/$BENCH_NAME && bench stop"
    echo -e "${YELLOW}  Bench status:${NC}         cd $INSTALL_HOME/$BENCH_NAME && bench status"
    echo -e "${YELLOW}  Restart services:${NC}     sudo supervisorctl restart all"
    echo -e "${YELLOW}  Check logs:${NC}           sudo supervisorctl tail"
    echo ""
    
    echo -e "${LIGHT_BLUE}Next Steps:${NC}"
    echo -e "${GREEN}1.${NC} Access your ERPNext at: http://$SITE_NAME or http://$server_ip"
    echo -e "${GREEN}2.${NC} Login with username: Administrator and your password"
    echo -e "${GREEN}3.${NC} Complete the setup wizard"
    echo -e "${GREEN}4.${NC} Configure your company details"
    echo ""
    
    if [[ "$BENCH_VERSION" == "develop" ]]; then
        echo -e "${RED}⚠  REMEMBER: You installed the DEVELOP branch!${NC}"
        echo -e "${RED}   This is not suitable for production use!${NC}"
        echo ""
    fi
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}            Thank you for using ERPNext!                      ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

run_single_installation() {
    clear
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}         ERPNext Single Installation                   ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # الخطوة 1: اختيار الإصدار
    select_version
    
    # الخطوة 2: جمع معلومات ما قبل التثبيت
    collect_pre_install_info
    
    # الخطوة 3: عرض الملخص والتأكيد
    show_install_summary
    
    # الخطوة 4: التحقق من التوافق
    verify_version_compatibility
    
    # الخطوة 5: تثبيت حزم النظام
    install_system_packages
    
    # الخطوة 6: تثبيت Python
    install_python
    
    # الخطوة 7: تثبيت wkhtmltopdf
    install_wkhtmltopdf
    
    # الخطوة 8: تثبيت MariaDB (مع إصلاح مشكلة التعارض)
    install_mariadb
    
    # الخطوة 9: تثبيت Node.js للمستخدم
    install_node_for_user "$INSTALL_USER" "$NODE_VERSION"
    
    # الخطوة 10: تثبيت Yarn للمستخدم
    install_yarn_for_user "$INSTALL_USER"
    
    # الخطوة 11: إعداد Supervisor
    fix_supervisor_for_user "$INSTALL_USER"
    
    # الخطوة 12: تثبيت bench
    install_bench_for_user "$INSTALL_USER" "$INSTALL_HOME"
    
    # الخطوة 13: إعداد Redis
    setup_redis_for_bench "$INSTALL_USER" "$INSTALL_HOME"
    
    # الخطوة 14: إنشاء الموقع
    create_site_for_user "$INSTALL_USER" "$INSTALL_HOME"
    
    # الخطوة 15: تثبيت ERPNext
    install_erpnext_for_user "$INSTALL_USER" "$INSTALL_HOME"
    
    # الخطوة 16: إعداد Production
    setup_production_for_user "$INSTALL_USER" "$INSTALL_HOME"
    
    # الخطوة 17: إعداد SSL
    setup_ssl_for_site
    
    # الخطوة 18: عرض الملخص النهائي
    show_final_summary
}

# القائمة الرئيسية
main_menu() {
    clear
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}       ERPNext Installation Manager                    ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Select installation mode:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Single ERPNext Installation ${LIGHT_BLUE}(Recommended)${NC}"
    echo -e "   • Install one ERPNext instance"
    echo -e "   • Production-ready setup"
    echo -e "   • Supports all versions"
    echo ""
    echo -e "${YELLOW}2.${NC} Multiple ERPNext Installations ${RED}(Advanced)${NC}"
    echo -e "   • Install multiple instances"
    echo -e "   • Different users/versions"
    echo -e "   • For development/testing"
    echo ""
    echo -e "${RED}3.${NC} Exit"
    echo ""
    
    read -p "Enter your choice (1-3): " choice
    
    case $choice in
        1)
            run_single_installation
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Multiple Installations Guide:${NC}"
            echo ""
            echo -e "${LIGHT_BLUE}To install multiple ERPNext instances:${NC}"
            echo ""
            echo -e "${GREEN}1.${NC} Run this script and choose option 1"
            echo -e "${GREEN}2.${NC} Select a DIFFERENT user for each installation"
            echo -e "${GREEN}3.${NC} Use a DIFFERENT bench folder name"
            echo -e "${GREEN}4.${NC} Use a DIFFERENT site name"
            echo ""
            echo -e "${YELLOW}Example for 2 installations:${NC}"
            echo -e "  ${LIGHT_BLUE}First installation:${NC}"
            echo -e "    • User: erpuser1"
            echo -e "    • Bench folder: frappe-bench-14"
            echo -e "    • Site: site1.example.com"
            echo ""
            echo -e "  ${LIGHT_BLUE}Second installation:${NC}"
            echo -e "    • User: erpuser2"
            echo -e "    • Bench folder: frappe-bench-15"
            echo -e "    • Site: site2.example.com"
            echo ""
            echo -e "${RED}⚠ Important:${NC} Each installation runs separately!"
            echo ""
            read -p "Press Enter to start first installation..." pause
            run_single_installation
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

# تشغيل القائمة الرئيسية
main_menu