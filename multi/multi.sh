#!/usr/bin/env bash

handle_error() {
    local line=$1
    local exit_code=$?
    echo "An error occurred on line $line with exit status $exit_code"
    exit $exit_code
}

trap 'handle_error $LINENO' ERR
set -e

server_ip=$(hostname -I | awk '{print $1}')

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
BENCH_VERSION=""
VERSION_NAME=""
DISTRO=""
OS_VERSION=""
BENCH_NAME=""
SITE_NAME=""
SQL_PASSWORD=""
ADMIN_PASSWORD=""
INSTALL_ERPNEXT=""
SETUP_PRODUCTION=""

check_os() {
    local os_name=$(lsb_release -is)
    OS_VERSION=$(lsb_release -rs)
    local os_supported=false
    local version_supported=false

    for i in "${SUPPORTED_DISTRIBUTIONS[@]}"; do
        if [[ "$i" = "$os_name" ]]; then
            os_supported=true
            break
        fi
    done

    for i in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ "$i" = "$OS_VERSION" ]]; then
            version_supported=true
            break
        fi
    done

    if [[ "$os_supported" = false ]] || [[ "$version_supported" = false ]]; then
        echo -e "${RED}This script is not compatible with your operating system or its version.${NC}"
        exit 1
    fi
    
    if [[ "$os_name" == "Ubuntu" ]]; then
        DISTRO="Ubuntu"
    elif [[ "$os_name" == "Debian" ]]; then
        DISTRO="Debian"
    fi
    
    echo -e "${GREEN}✓ OS: $DISTRO $OS_VERSION is supported${NC}"
}

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

# Function to create user if doesn't exist
create_user_if_not_exists() {
    local user="$1"
    
    if ! id "$user" &>/dev/null; then
        echo -e "${YELLOW}Creating new user: $user...${NC}"
        
        # Create user without password prompt
        sudo adduser --disabled-password --gecos "" "$user" > /dev/null 2>&1
        
        # Add to sudo group
        sudo usermod -aG sudo "$user" > /dev/null 2>&1
        
        # Set default password
        echo "$user:$DEFAULT_PASSWORD" | sudo chpasswd > /dev/null 2>&1
        
        echo -e "${GREEN}✓ User $user created successfully${NC}"
        echo -e "${YELLOW}Default password: $DEFAULT_PASSWORD${NC}"
        echo -e "${YELLOW}Please change password after first login${NC}"
    else
        echo -e "${GREEN}User $user already exists${NC}"
    fi
}

# Function to create or select user
select_or_create_user() {
    echo -e "${YELLOW}Select installation user:${NC}"
    echo "1. Use current user ($(whoami))"
    echo "2. Create new user"
    echo "3. Select existing user"
    
    read -p "Enter choice (1-3): " user_choice
    
    case $user_choice in
        1)
            INSTALL_USER=$(whoami)
            INSTALL_HOME=$HOME
            echo -e "${GREEN}Using current user: $INSTALL_USER${NC}"
            ;;
        2)
            read -p "Enter new username: " new_user
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
    
    return 0
}

# Function to generate unique port numbers
generate_unique_ports() {
    local version="$1"
    local bench_name="$2"
    local user="$3"
    
    # Create a unique identifier for this installation
    local install_id="${user}_${bench_name}_${version}"
    
    # Generate simple hash from install_id
    local hash_num=0
    for (( i=0; i<${#install_id}; i++ )); do
        char=$(printf '%d' "'${install_id:$i:1}")
        hash_num=$((hash_num + char))
    done
    
    # Generate unique ports for this installation
    local mariadb_port=$((13306 + (hash_num % 1000)))
    local redis_queue_port=$((15000 + (hash_num % 1000)))
    local redis_cache_port=$((16000 + (hash_num % 1000)))
    local redis_socketio_port=$((17000 + (hash_num % 1000)))
    local bench_port=$((18000 + (hash_num % 1000)))
    
    # Check if ports are in use and adjust if needed
    while nc -z 127.0.0.1 $mariadb_port 2>/dev/null; do
        mariadb_port=$((mariadb_port + 1))
    done
    
    while nc -z 127.0.0.1 $redis_queue_port 2>/dev/null; do
        redis_queue_port=$((redis_queue_port + 1))
    done
    
    while nc -z 127.0.0.1 $redis_cache_port 2>/dev/null; do
        redis_cache_port=$((redis_cache_port + 1))
    done
    
    while nc -z 127.0.0.1 $redis_socketio_port 2>/dev/null; do
        redis_socketio_port=$((redis_socketio_port + 1))
    done
    
    while nc -z 127.0.0.1 $bench_port 2>/dev/null; do
        bench_port=$((bench_port + 1))
    done
    
    echo "$mariadb_port:$redis_queue_port:$redis_cache_port:$redis_socketio_port:$bench_port"
}

# Function to extract app name from setup.py
extract_app_name_from_setup() {
    local setup_file="$1"
    local app_name=""
    
    if [[ -f "$setup_file" ]]; then
        app_name=$(grep -oE 'name\s*=\s*["\047][^"\047]+["\047]' "$setup_file" 2>/dev/null | head -1 | sed -E 's/.*name\s*=\s*["\047]([^"\047]+)["\047].*/\1/')
        
        if [[ -z "$app_name" ]]; then
            app_name=$(grep -oE 'name\s*=\s*["\047][^"\047]*["\047]' "$setup_file" 2>/dev/null | head -1 | sed -E 's/.*["\047]([^"\047]+)["\047].*/\1/')
        fi
        
        if [[ -z "$app_name" ]]; then
            app_name=$(awk '/setup\s*\(/,/\)/ { if (/name\s*=/) { gsub(/.*name\s*=\s*["\047]/, ""); gsub(/["\047].*/, ""); print; exit } }' "$setup_file" 2>/dev/null | head -1 | tr -d ' \t')
        fi
        
        if [[ -z "$app_name" ]]; then
            app_name=$(grep "name.*=" "$setup_file" 2>/dev/null | head -1 | sed -E 's/.*["\047]([^"\047]+)["\047].*/\1/' | tr -d ' \t')
        fi
        
        if [[ -z "$app_name" ]]; then
            local app_base_dir=$(dirname "$setup_file")
            for subdir in "$app_base_dir"/*/; do
                if [[ -d "$subdir" && -f "$subdir/__init__.py" ]]; then
                    local module_dir=$(basename "$subdir")
                    if [[ -n "$module_dir" && "$module_dir" != "." && "$module_dir" != "tests" && "$module_dir" != "docs" ]]; then
                        app_name="$module_dir"
                        break
                    fi
                fi
            done
        fi
    fi
    
    echo "$app_name"
}

# Function to check existing installations
check_existing_installations() {
    local bench_name="$1"
    local existing_installations=()
    local installation_paths=()
    
    local search_paths=(
        "$HOME/$bench_name"
        "/home/*/$bench_name"
        "/opt/$bench_name"
        "/var/www/$bench_name"
    )
    
    echo -e "${YELLOW}Checking for existing ERPNext installations...${NC}"
    
    for path_pattern in "${search_paths[@]}"; do
        for path in $path_pattern; do
            if [[ -d "$path" ]] && [[ -f "$path/apps/frappe/frappe/__init__.py" ]]; then
                local version_info=""
                if [[ -f "$path/apps/frappe/frappe/__version__.py" ]]; then
                    version_info=$(grep -o 'version.*=.*[0-9]' "$path/apps/frappe/frappe/__version__.py" 2>/dev/null || echo "unknown")
                fi
                
                local branch_info=""
                if [[ -d "$path/apps/frappe/.git" ]]; then
                    branch_info=$(cd "$path/apps/frappe" && git branch --show-current 2>/dev/null || echo "unknown")
                fi
                
                existing_installations+=("$path")
                installation_paths+=("Path: $path | Version: $version_info | Branch: $branch_info")
            fi
        done
    done
    
    if [[ ${#existing_installations[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}⚠️  EXISTING ERPNEXT INSTALLATION(S) DETECTED ⚠️${NC}"
        echo ""
        echo -e "${YELLOW}Found the following ERPNext installation(s):${NC}"
        for info in "${installation_paths[@]}"; do
            echo -e "${LIGHT_BLUE}• $info${NC}"
        done
        echo ""
        echo -e "${RED}WARNING: Installing different ERPNext versions on the same server can cause:${NC}"
        echo -e "${YELLOW}• Port conflicts (Redis, Node.js services)${NC}"
        echo -e "${YELLOW}• Dependency version conflicts${NC}"
        echo -e "${YELLOW}• Supervisor configuration conflicts${NC}"
        echo -e "${YELLOW}• Database schema incompatibilities${NC}"
        echo -e "${YELLOW}• System instability${NC}"
        echo ""
        echo -e "${LIGHT_BLUE}Recommended actions:${NC}"
        echo -e "${GREEN}1. Use the existing installation if it meets your needs${NC}"
        echo -e "${GREEN}2. Backup and remove existing installation before installing new version${NC}"
        echo -e "${GREEN}3. Use a fresh server/container for the new installation${NC}"
        echo -e "${GREEN}4. Use different users/paths if you must have multiple versions${NC}"
        echo ""
        
        read -p "Do you want to continue anyway? (yes/no): " conflict_confirm
        conflict_confirm=$(echo "$conflict_confirm" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$conflict_confirm" != "yes" && "$conflict_confirm" != "y" ]]; then
            echo -e "${GREEN}Installation cancelled. Good choice for system stability!${NC}"
            exit 0
        else
            echo -e "${YELLOW}Proceeding with installation despite existing installations...${NC}"
            echo -e "${RED}You've been warned about potential conflicts!${NC}"
        fi
    else
        echo -e "${GREEN}✓ No existing ERPNext installations found.${NC}"
    fi
}

# Function to detect best branch for apps
detect_best_branch() {
    local repo_url="$1"
    local preferred_version="$2"
    local repo_name="$3"
    
    echo -e "${LIGHT_BLUE}🔍 Detecting available branches for $repo_name...${NC}" >&2
    
    local branches=$(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | sort -V)
    
    if [[ -z "$branches" ]]; then
        echo -e "${RED}⚠ Could not fetch branches from $repo_url${NC}" >&2
        echo ""
        return 1
    fi
    
    local branch_priorities=()
    
    case "$repo_name" in
        "crm"|"helpdesk"|"builder"|"drive"|"gameplan")
            echo -e "${YELLOW}🎯 Using 'main' branch for Frappe $repo_name (recommended)${NC}" >&2
            if echo "$branches" | grep -q "^main$"; then
                echo -e "${GREEN}✅ Selected branch: main${NC}" >&2
                echo "main"
                return 0
            elif echo "$branches" | grep -q "^master$"; then
                echo -e "${YELLOW}⚠ 'main' not found, falling back to 'master'${NC}" >&2
                echo "master"
                return 0
            fi
            ;;
        "hrms"|"lms")
            echo -e "${YELLOW}🎯 Detecting best branch for Frappe $repo_name...${NC}" >&2
            ;;
    esac
    
    case "$preferred_version" in
        "version-16")
            branch_priorities=("version-16" "version-15" "develop" "main" "master" "version-14" "version-13")
            ;;
        "version-15"|"develop")
            branch_priorities=("version-15" "develop" "main" "master" "version-14" "version-13")
            ;;
        "version-14")
            branch_priorities=("version-14" "main" "master" "develop" "version-15" "version-13")
            ;;
        "version-13")
            branch_priorities=("version-13" "main" "master" "version-14" "develop" "version-15")
            ;;
        *)
            branch_priorities=("main" "master" "develop")
            ;;
    esac
    
    for priority_branch in "${branch_priorities[@]}"; do
        if echo "$branches" | grep -q "^$priority_branch$"; then
            echo -e "${GREEN}✅ Selected branch: $priority_branch${NC}" >&2
            echo "$priority_branch"
            return 0
        fi
    done
    
    local fallback_branch=$(echo "$branches" | head -1)
    echo -e "${YELLOW}⚠ Using fallback branch: $fallback_branch${NC}" >&2
    echo "$fallback_branch"
    return 0
}

# Main installation function
install_erpnext_single() {
    echo -e "${LIGHT_BLUE}Starting ERPNext $VERSION_NAME installation for user: $INSTALL_USER${NC}"
    echo ""
    
    # Check OS compatibility
    if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
        if [[ "$DISTRO" != "Ubuntu" && "$DISTRO" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$DISTRO" == "Ubuntu" && "$OS_VERSION" < "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$DISTRO" == "Debian" && "$OS_VERSION" < "12" ]]; then
            echo -e "${RED}Your Debian version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        fi
    fi

    if [[ "$BENCH_VERSION" != "version-15" && "$BENCH_VERSION" != "version-16" && "$BENCH_VERSION" != "develop" ]]; then
        if [[ "$DISTRO" != "Ubuntu" && "$DISTRO" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for $VERSION_NAME.${NC}"
            exit 1
        elif [[ "$DISTRO" == "Ubuntu" && "$OS_VERSION" > "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is not supported for $VERSION_NAME.${NC}"
            echo -e "${YELLOW}ERPNext v13/v14 only support Ubuntu up to 22.04. Please use ERPNext v15/v16 for Ubuntu 24.04.${NC}"
            exit 1
        elif [[ "$DISTRO" == "Debian" && "$OS_VERSION" > "11" ]]; then
            echo -e "${YELLOW}Warning: Your Debian version is above the tested range for $VERSION_NAME, but we'll continue.${NC}"
            sleep 2
        fi
    fi
    
    # Check existing installations
    check_existing_installations "$BENCH_NAME"
    
    # Create a temporary script to run as the target user
    TEMP_SCRIPT="/tmp/erpnext_install_$$.sh"
    
    cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash
set -e

# Variables passed from main script
INSTALL_USER="$1"
BENCH_VERSION="$2"
BENCH_NAME="$3"
SITE_NAME="$4"
SQL_PASSWORD="$5"
ADMIN_PASSWORD="$6"
INSTALL_ERPNEXT="$7"
SETUP_PRODUCTION="$8"
DISTRO="$9"
OS_VERSION="${10}"

echo "=== Starting ERPNext Installation ==="
echo "User: $(whoami)"
echo "Home: $HOME"
echo "Bench: $BENCH_NAME"
echo "Version: $BENCH_VERSION"
echo "Site: $SITE_NAME"
echo "================================"

# Change to home directory
cd "$HOME"

# System updates
echo "Updating system packages..."
sudo apt update
sudo apt upgrade -y

# Install preliminary packages
echo "Installing preliminary packages..."
sudo apt install software-properties-common git curl wget python3-pip python3-dev python3-venv python3-setuptools \
    mariadb-server mariadb-client libmysqlclient-dev redis-server nginx supervisor cron whiptail -y

# Special handling for Ubuntu 24.04
if [[ "$DISTRO" == "Ubuntu" && "$OS_VERSION" == "24.04" ]]; then
    echo "Configuring for Ubuntu 24.04..."
    sudo apt update
    sudo apt install -y supervisor
    
    # Create default supervisor config if missing
    if [ ! -f /etc/supervisor/supervisord.conf ]; then
        sudo tee /etc/supervisor/supervisord.conf > /dev/null <<'SUPERVISOR_CONF'
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
SUPERVISOR_CONF
    fi
    
    sudo systemctl enable supervisor
    sudo systemctl restart supervisor
fi

# Install Python based on version requirements
echo "Checking Python version..."
py_version=$(python3 --version 2>&1 | awk '{print $2}')
py_major=$(echo "$py_version" | cut -d '.' -f 1)
py_minor=$(echo "$py_version" | cut -d '.' -f 2)

required_python_minor=10
required_python_label="3.10"

if [[ "$BENCH_VERSION" == "version-16" ]]; then
    required_python_minor=14
    required_python_label="3.14"
fi

if [[ -z "$py_version" ]] || [[ "$py_major" -lt 3 ]] || [[ "$py_major" -eq 3 && "$py_minor" -lt "$required_python_minor" ]]; then
    echo "Installing Python $required_python_label..."
    sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
        libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget libbz2-dev
    
    if [[ "$required_python_minor" == "14" ]]; then
        wget https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tgz
        tar -xf Python-3.14.0.tgz
        cd Python-3.14.0
        ./configure --prefix=/usr/local --enable-optimizations --enable-shared LDFLAGS="-Wl,-rpath /usr/local/lib"
        make -j "$(nproc)"
        sudo make altinstall
        cd ..
        sudo rm -rf Python-3.14.0
        sudo rm Python-3.14.0.tgz
        pip3.14 install --user --upgrade pip
    else
        sudo apt install -y python3.10 python3.10-venv python3.10-dev
    fi
fi

# Install additional Python packages
echo "Installing additional Python packages..."
sudo apt install -y python3-pip redis-server

# Install wkhtmltopdf
echo "Installing wkhtmltopdf..."
arch=$(uname -m)
case $arch in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $arch"; exit 1 ;;
esac

sudo apt install -y fontconfig libxrender1 xfonts-75dpi xfonts-base
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_"$arch".deb
sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_"$arch".deb || true
sudo cp /usr/local/bin/wkhtmlto* /usr/bin/
sudo chmod a+x /usr/bin/wk*
sudo rm wkhtmltox_0.12.6.1-2.jammy_"$arch".deb
sudo apt --fix-broken install -y

# Install MariaDB development libraries
echo "Installing MariaDB development libraries..."
sudo apt install -y pkg-config default-libmysqlclient-dev

# Configure MariaDB
echo "Configuring MariaDB..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$SQL_PASSWORD';"
sudo mysql -u root -p"$SQL_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
sudo mysql -u root -p"$SQL_PASSWORD" -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
sudo mysql -u root -p"$SQL_PASSWORD" -e "FLUSH PRIVILEGES;"

# Add MariaDB settings
sudo tee -a /etc/mysql/my.cnf > /dev/null <<'MYSQL_CONF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
MYSQL_CONF

sudo systemctl restart mariadb

# Install NVM and Node.js
echo "Installing NVM and Node.js..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Install appropriate Node version
if [[ "$BENCH_VERSION" == "version-16" ]]; then
    nvm install 20
    nvm alias default 20
    node_version="20"
elif [[ "$DISTRO" == "Ubuntu" && "$OS_VERSION" == "24.04" ]]; then
    nvm install 20
    nvm alias default 20
    node_version="20"
elif [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "develop" ]]; then
    nvm install 18
    nvm alias default 18
    node_version="18"
else
    nvm install 16
    nvm alias default 16
    node_version="16"
fi

# Install yarn
npm install -g yarn

# Install bench
echo "Installing bench..."
sudo pip3 install frappe-bench

# Initialize bench
echo "Initializing bench: $BENCH_NAME..."
bench init "$BENCH_NAME" --version "$BENCH_VERSION" --verbose

cd "$BENCH_NAME"

# Create site
echo "Creating site: $SITE_NAME..."
bench new-site "$SITE_NAME" \
    --db-root-username root \
    --db-root-password "$SQL_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD"

# Start Redis instances for v15/v16/develop
if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
    echo "Starting Redis instances..."
    redis-server --port 11000 --daemonize yes --bind 127.0.0.1
    redis-server --port 12000 --daemonize yes --bind 127.0.0.1
    redis-server --port 13000 --daemonize yes --bind 127.0.0.1
fi

# Install ERPNext if requested
if [[ "$INSTALL_ERPNEXT" == "yes" || "$INSTALL_ERPNEXT" == "y" ]]; then
    echo "Installing ERPNext..."
    bench get-app erpnext --branch "$BENCH_VERSION"
    bench --site "$SITE_NAME" install-app erpnext
fi

# Setup production if requested
if [[ "$SETUP_PRODUCTION" == "yes" || "$SETUP_PRODUCTION" == "y" ]]; then
    echo "Setting up production..."
    
    # Patch for Ubuntu 24.04
    if [[ "$DISTRO" == "Ubuntu" && "$OS_VERSION" == "24.04" ]]; then
        echo "Applying patches for Ubuntu 24.04..."
        
        # Patch Ansible nginx condition
        python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        playbook_file="/usr/local/lib/python${python_version}/dist-packages/bench/playbooks/roles/nginx/tasks/vhosts.yml"
        if [ -f "$playbook_file" ]; then
            sudo sed -i 's/when: nginx_vhosts/when: nginx_vhosts | length > 0/' "$playbook_file"
        fi
        
        # Ensure nginx is installed and running
        sudo apt install -y nginx
        sudo systemctl stop nginx 2>/dev/null || true
        sudo rm -f /var/run/nginx.pid || true
        sudo rm -f /etc/nginx/sites-enabled/default || true
        sudo systemctl start nginx
    fi
    
    # Setup production
    yes | sudo bench setup production "$INSTALL_USER"
    
    # Configure supervisor
    if grep -q "chown=" /etc/supervisor/supervisord.conf; then
        sudo sed -i "s/chown=.*/chown=$INSTALL_USER:$INSTALL_USER/" /etc/supervisor/supervisord.conf
    else
        sudo sed -i "/\[unix_http_server\]/a chown=$INSTALL_USER:$INSTALL_USER" /etc/supervisor/supervisord.conf
    fi
    
    sudo systemctl restart supervisor
    
    # Enable scheduler
    bench --site "$SITE_NAME" scheduler enable
    bench --site "$SITE_NAME" scheduler resume
    
    # Additional setup for v15/v16/develop
    if [[ "$BENCH_VERSION" == "version-15" || "$BENCH_VERSION" == "version-16" || "$BENCH_VERSION" == "develop" ]]; then
        bench setup socketio
        yes | bench setup supervisor
        bench setup redis
        sudo supervisorctl reload
    fi
    
    # Restart services
    sudo systemctl restart redis-server
    sudo supervisorctl restart all || echo "Some services may have failed to restart"
    
    echo "Production setup complete!"
else
    echo "Development setup complete!"
    echo "To start development server:"
    echo "  cd ~/$BENCH_NAME && bench start"
fi

# Set permissions
sudo chmod 755 "$HOME"

echo ""
echo "========================================"
echo "✅ ERPNext Installation Complete!"
echo "========================================"
echo "Bench location: ~/$BENCH_NAME"
echo "Site: $SITE_NAME"
echo "Version: $BENCH_VERSION"
echo ""
if [[ "$SETUP_PRODUCTION" == "yes" || "$SETUP_PRODUCTION" == "y" ]]; then
    echo "🌐 Access your site at: http://$(hostname -I | awk '{print $1}')"
    echo "   or https://$SITE_NAME (if SSL configured)"
else
    echo "💻 Start development server:"
    echo "   cd ~/$BENCH_NAME && bench start"
    echo "   Then visit: http://localhost:8000"
fi
echo "========================================"
EOF

    # Make script executable
    chmod +x "$TEMP_SCRIPT"
    
    # Run the installation script as the target user
    echo -e "${YELLOW}Running installation as user: $INSTALL_USER...${NC}"
    echo -e "${YELLOW}This may take 15-30 minutes depending on your system...${NC}"
    
    sudo -u "$INSTALL_USER" bash "$TEMP_SCRIPT" \
        "$INSTALL_USER" \
        "$BENCH_VERSION" \
        "$BENCH_NAME" \
        "$SITE_NAME" \
        "$SQL_PASSWORD" \
        "$ADMIN_PASSWORD" \
        "$INSTALL_ERPNEXT" \
        "$SETUP_PRODUCTION" \
        "$DISTRO" \
        "$OS_VERSION"
    
    # Clean up
    rm -f "$TEMP_SCRIPT"
    
    echo -e "${GREEN}✅ Installation completed successfully!${NC}"
}

# Function for multiple installations
install_multiple_versions() {
    echo -e "${YELLOW}Multiple versions installation selected${NC}"
    
    # Select user
    select_or_create_user || exit 1
    
    echo -e "${GREEN}User: $INSTALL_USER${NC}"
    echo ""
    
    declare -a versions_to_install=()
    declare -a bench_names=()
    
    # Collect versions to install
    while true; do
        echo -e "${YELLOW}Add version to install:${NC}"
        echo "1. Version 13"
        echo "2. Version 14"
        echo "3. Version 15"
        echo "4. Version 16"
        echo "5. Develop"
        echo "6. Done adding versions"
        
        read -p "Enter choice (1-6): " version_add_choice
        
        case $version_add_choice in
            1)
                versions_to_install+=("version-13")
                read -p "Enter bench name for Version 13 (default: frappe-bench-13): " bench_name
                bench_names+=("${bench_name:-frappe-bench-13}")
                ;;
            2)
                versions_to_install+=("version-14")
                read -p "Enter bench name for Version 14 (default: frappe-bench-14): " bench_name
                bench_names+=("${bench_name:-frappe-bench-14}")
                ;;
            3)
                versions_to_install+=("version-15")
                read -p "Enter bench name for Version 15 (default: frappe-bench-15): " bench_name
                bench_names+=("${bench_name:-frappe-bench-15}")
                ;;
            4)
                versions_to_install+=("version-16")
                read -p "Enter bench name for Version 16 (default: frappe-bench-16): " bench_name
                bench_names+=("${bench_name:-frappe-bench-16}")
                ;;
            5)
                versions_to_install+=("develop")
                read -p "Enter bench name for Develop (default: frappe-bench-develop): " bench_name
                bench_names+=("${bench_name:-frappe-bench-develop}")
                ;;
            6)
                break
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                ;;
        esac
        echo ""
    done
    
    if [ ${#versions_to_install[@]} -eq 0 ]; then
        echo -e "${RED}No versions selected. Exiting.${NC}"
        exit 0
    fi
    
    # Show summary
    echo -e "${GREEN}Will install the following versions for user '$INSTALL_USER':${NC}"
    for i in "${!versions_to_install[@]}"; do
        version_name=""
        case "${versions_to_install[$i]}" in
            "version-13") version_name="Version 13" ;;
            "version-14") version_name="Version 14" ;;
            "version-15") version_name="Version 15" ;;
            "version-16") version_name="Version 16" ;;
            "develop") version_name="Develop" ;;
        esac
        echo -e "  • $version_name -> ${bench_names[$i]}"
    done
    
    read -p "Continue? (yes/no): " confirm_multiple
    confirm_multiple=$(echo "$confirm_multiple" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$confirm_multiple" != "yes" && "$confirm_multiple" != "y" ]]; then
        echo -e "${RED}Installation cancelled.${NC}"
        exit 0
    fi
    
    # Get common parameters
    echo -e "${YELLOW}Enter common parameters:${NC}"
    SQL_PASSWORD=$(ask_twice "Enter MariaDB root password" "true")
    ADMIN_PASSWORD=$(ask_twice "Enter Administrator password" "true")
    
    # Install each version
    for i in "${!versions_to_install[@]}"; do
        echo ""
        echo -e "${LIGHT_BLUE}══════════════════════════════════════════════════════════${NC}"
        echo -e "${LIGHT_BLUE}  Installing ${versions_to_install[$i]} (${bench_names[$i]})  ${NC}"
        echo -e "${LIGHT_BLUE}══════════════════════════════════════════════════════════${NC}"
        
        # Get version-specific parameters
        case "${versions_to_install[$i]}" in
            "version-13") VERSION_NAME="Version 13" ;;
            "version-14") VERSION_NAME="Version 14" ;;
            "version-15") VERSION_NAME="Version 15" ;;
            "version-16") VERSION_NAME="Version 16" ;;
            "develop") VERSION_NAME="Develop" ;;
        esac
        
        BENCH_VERSION="${versions_to_install[$i]}"
        BENCH_NAME="${bench_names[$i]}"
        
        read -p "Enter site name for $VERSION_NAME: " SITE_NAME
        read -p "Install ERPNext for $VERSION_NAME? (yes/no): " INSTALL_ERPNEXT
        INSTALL_ERPNEXT=$(echo "$INSTALL_ERPNEXT" | tr '[:upper:]' '[:lower:]')
        read -p "Setup production for $VERSION_NAME? (yes/no): " SETUP_PRODUCTION
        SETUP_PRODUCTION=$(echo "$SETUP_PRODUCTION" | tr '[:upper:]' '[:lower:]')
        
        # For develop branch, show warning
        if [[ "$BENCH_VERSION" == "develop" ]]; then
            echo ""
            echo -e "${RED}⚠️  WARNING: DEVELOP VERSION ⚠️${NC}"
            echo ""
            echo -e "${YELLOW}The develop branch contains bleeding-edge code that:${NC}"
            echo -e "${RED}• Changes daily and may be unstable${NC}"
            echo -e "${RED}• Can cause data corruption or system crashes${NC}"
            echo -e "${RED}• Is NOT suitable for production or important data${NC}"
            echo -e "${RED}• Has limited community support${NC}"
            echo ""
            read -p "Do you understand the risks and want to continue? (yes/no): " develop_confirm
            develop_confirm=$(echo "$develop_confirm" | tr '[:upper:]' '[:lower:]')
            
            if [[ "$develop_confirm" != "yes" && "$develop_confirm" != "y" ]]; then
                echo -e "${GREEN}Skipping develop branch installation.${NC}"
                continue
            fi
        fi
        
        # Run installation
        install_erpnext_single
        
        echo -e "${GREEN}✓ Completed $VERSION_NAME installation${NC}"
    done
    
    # Summary
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}     All installations completed successfully!           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    
    echo -e "${YELLOW}Summary of installations for user '$INSTALL_USER':${NC}"
    for i in "${!versions_to_install[@]}"; do
        version_name=""
        case "${versions_to_install[$i]}" in
            "version-13") version_name="Version 13" ;;
            "version-14") version_name="Version 14" ;;
            "version-15") version_name="Version 15" ;;
            "version-16") version_name="Version 16" ;;
            "develop") version_name="Develop" ;;
        esac
        echo -e "  • ${bench_names[$i]} ($version_name)"
    done
    echo ""
    echo -e "${LIGHT_BLUE}To start benches:${NC}"
    for i in "${!versions_to_install[@]}"; do
        echo -e "  sudo -u $INSTALL_USER bash -c 'cd ~/${bench_names[$i]} && bench start'"
    done
    echo ""
    echo -e "${YELLOW}Note: Each bench runs on different ports to avoid conflicts.${NC}"
}

# Main menu
main_menu() {
    clear
    echo -e "${LIGHT_BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${LIGHT_BLUE}║        ERPNext Multi-Version Installation Manager       ║${NC}"
    echo -e "${LIGHT_BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check OS
    check_os
    
    echo -e "${YELLOW}Choose installation mode:${NC}"
    echo "1. Single ERPNext installation"
    echo "2. Multiple ERPNext versions (same user)"
    echo "3. Exit"
    
    read -p "Enter choice (1-3): " mode_choice
    
    case $mode_choice in
        1)
            echo -e "${YELLOW}Single installation selected${NC}"
            
            # Select user
            select_or_create_user || exit 1
            
            # Select version
            echo -e "${YELLOW}Select ERPNext version:${NC}"
            echo "1. Version 13"
            echo "2. Version 14" 
            echo "3. Version 15"
            echo "4. Version 16"
            echo "5. Develop"
            
            read -p "Enter choice (1-5): " version_choice
            
            case $version_choice in
                1) 
                    BENCH_VERSION="version-13"
                    VERSION_NAME="Version 13"
                    ;;
                2)
                    BENCH_VERSION="version-14"
                    VERSION_NAME="Version 14"
                    ;;
                3)
                    BENCH_VERSION="version-15"
                    VERSION_NAME="Version 15"
                    ;;
                4)
                    BENCH_VERSION="version-16"
                    VERSION_NAME="Version 16"
                    ;;
                5)
                    BENCH_VERSION="develop"
                    VERSION_NAME="Develop"
                    
                    echo ""
                    echo -e "${RED}⚠️  WARNING: DEVELOP VERSION ⚠️${NC}"
                    echo ""
                    echo -e "${YELLOW}The develop branch contains bleeding-edge code that:${NC}"
                    echo -e "${RED}• Changes daily and may be unstable${NC}"
                    echo -e "${RED}• Can cause data corruption or system crashes${NC}"
                    echo -e "${RED}• Is NOT suitable for production or important data${NC}"
                    echo -e "${RED}• Has limited community support${NC}"
                    echo ""
                    read -p "Do you understand the risks and want to continue? (yes/no): " develop_confirm
                    develop_confirm=$(echo "$develop_confirm" | tr '[:upper:]' '[:lower:]')
                    
                    if [[ "$develop_confirm" != "yes" && "$develop_confirm" != "y" ]]; then
                        echo -e "${GREEN}Installation cancelled. Please select a stable version.${NC}"
                        exit 0
                    fi
                    ;;
                *)
                    echo -e "${RED}Invalid choice${NC}"
                    exit 1
                    ;;
            esac
            
            echo -e "${GREEN}Selected: $VERSION_NAME${NC}"
            
            # Get installation parameters
            read -p "Enter bench name (default: frappe-bench): " BENCH_NAME
            BENCH_NAME=${BENCH_NAME:-frappe-bench}
            
            read -p "Enter site name: " SITE_NAME
            SQL_PASSWORD=$(ask_twice "Enter MariaDB root password" "true")
            ADMIN_PASSWORD=$(ask_twice "Enter Administrator password" "true")
            
            read -p "Install ERPNext? (yes/no): " INSTALL_ERPNEXT
            INSTALL_ERPNEXT=$(echo "$INSTALL_ERPNEXT" | tr '[:upper:]' '[:lower:]')
            
            read -p "Setup production? (yes/no): " SETUP_PRODUCTION
            SETUP_PRODUCTION=$(echo "$SETUP_PRODUCTION" | tr '[:upper:]' '[:lower:]")
            
            # Run installation
            install_erpnext_single
            ;;
            
        2)
            install_multiple_versions
            ;;
            
        3)
            echo -e "${GREEN}Exiting. Goodbye!${NC}"
            exit 0
            ;;
            
        *)
            echo -e "${RED}Invalid choice. Exiting.${NC}"
            exit 1
            ;;
    esac
}

# Run main menu
main_menu