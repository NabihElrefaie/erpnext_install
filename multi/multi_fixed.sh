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

check_os() {
    local os_name=$(lsb_release -is)
    local os_version=$(lsb_release -rs)
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
      if [ "$(lsb_release -si)" == "Ubuntu" ]; then
        DISTRO='Ubuntu'
      else
        DISTRO='Debian'
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

check_existing_installations() {
    local existing_installations=()
    local installation_paths=()
    
    local search_paths=(
        "$HOME/frappe-bench*"
        "/home/*/frappe-bench*"
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

# MAIN SINGLE INSTALLATION FUNCTION - COMPLETE FROM single.sh
run_single_installation() {
    echo -e "${LIGHT_BLUE}Welcome to the ERPNext Installer...${NC}"
    echo -e "\n"
    sleep 3

    echo -e "${YELLOW}Please enter the number of the corresponding ERPNext version you wish to install:${NC}"

    versions=("Version 13" "Version 14" "Version 15" "Version 16" "Develop")
    select version_choice in "${versions[@]}"; do
        case $REPLY in
            1) bench_version="version-13"; break;;
            2) bench_version="version-14"; break;;
            3) bench_version="version-15"; break;;
            4) bench_version="version-16"; break;;
            5) bench_version="develop"; 
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
               break;;
            *) echo -e "${RED}Invalid option. Please select a valid version.${NC}";;
        esac
    done

    echo -e "${GREEN}You have selected $version_choice for installation.${NC}"
    echo -e "${GREEN}Proceeding with the installation of $version_choice.${NC}"
    sleep 1

# Pre-installation information collection
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}         PRE-INSTALLATION INFORMATION COLLECTION          ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Select or create user for installation
    echo -e "${YELLOW}Step 1: Select installation user${NC}"
    select_or_create_user
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}User selection failed. Exiting.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ User selected: $INSTALL_USER${NC}"
    echo -e "${GREEN}✓ Home directory: $INSTALL_HOME${NC}"
    echo ""
    
    # Collect bench name
    echo -e "${YELLOW}Step 2: Enter bench folder name${NC}"
    read -p "Enter bench folder name (default: frappe-bench): " bench_name
    bench_name=${bench_name:-frappe-bench}
    echo -e "${GREEN}✓ Bench folder: $bench_name${NC}"
    echo ""
    
    # Collect site name
    echo -e "${YELLOW}Step 3: Enter site name${NC}"
    read -p "Enter site name (FQDN if planning SSL later): " site_name
    while [[ -z "$site_name" ]]; do
        echo -e "${RED}Site name cannot be empty. Please enter a valid site name.${NC}"
        read -p "Enter site name (FQDN if planning SSL later): " site_name
    done
    echo -e "${GREEN}✓ Site name: $site_name${NC}"
    echo ""
    
    # Collect SQL password
    echo -e "${YELLOW}Step 4: Set SQL root password${NC}"
    sqlpasswrd=$(ask_twice "What is your required SQL root password" "true")
    echo -e "${GREEN}✓ SQL password set${NC}"
    echo ""
    
    # Collect admin password
    echo -e "${YELLOW}Step 5: Set Administrator password${NC}"
    adminpasswrd=$(ask_twice "Enter the Administrator password" "true")
    echo -e "${GREEN}✓ Admin password set${NC}"
    echo ""
    
    # Collect email for SSL (optional)
    echo -e "${YELLOW}Step 6: Email address (optional, for SSL certificates)${NC}"
    read -p "Enter email address for SSL (press Enter to skip): " email_address
    if [[ -n "$email_address" ]]; then
        echo -e "${GREEN}✓ Email: $email_address${NC}"
    else
        echo -e "${YELLOW}ℹ Email skipped (can add later)${NC}"
    fi
    echo ""
    
    # Show summary
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${LIGHT_BLUE}             INSTALLATION SUMMARY                       ${NC}"
    echo -e "${LIGHT_BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}User:${NC}         $INSTALL_USER"
    echo -e "${GREEN}Home:${NC}         $INSTALL_HOME"
    echo -e "${GREEN}Bench:${NC}        $bench_name"
    echo -e "${GREEN}Site:${NC}         $site_name"
    echo -e "${GREEN}SQL Password:${NC}  ✓ Set"
    echo -e "${GREEN}Admin Password:${NC} ✓ Set"
    if [[ -n "$email_address" ]]; then
        echo -e "${GREEN}Email:${NC}        $email_address"
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
    
    check_existing_installations

    if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
        if [[ "$(lsb_release -si)" != "Ubuntu" && "$(lsb_release -si)" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$(lsb_release -si)" == "Ubuntu" && "$(lsb_release -rs)" < "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        elif [[ "$(lsb_release -si)" == "Debian" && "$(lsb_release -rs)" < "12" ]]; then
            echo -e "${RED}Your Debian version is below the minimum required to support Version 15/16/Develop.${NC}"
            exit 1
        fi
    fi

    if [[ "$bench_version" != "version-15" && "$bench_version" != "version-16" && "$bench_version" != "develop" ]]; then
        if [[ "$(lsb_release -si)" != "Ubuntu" && "$(lsb_release -si)" != "Debian" ]]; then
            echo -e "${RED}Your Distro is not supported for $version_choice.${NC}"
            exit 1
        elif [[ "$(lsb_release -si)" == "Ubuntu" && "$(lsb_release -rs)" > "22.04" ]]; then
            echo -e "${RED}Your Ubuntu version is not supported for $version_choice.${NC}"
            echo -e "${YELLOW}ERPNext v13/v14 only support Ubuntu up to 22.04. Please use ERPNext v15/v16 for Ubuntu 24.04.${NC}"
            exit 1
        elif [[ "$(lsb_release -si)" == "Debian" && "$(lsb_release -rs)" > "11" ]]; then
            echo -e "${YELLOW}Warning: Your Debian version is above the tested range for $version_choice, but we'll continue.${NC}"
            sleep 2
        fi
    fi

# OS check will be done during installation

echo -e "${YELLOW}Starting system preparation...${NC}"
    echo -e "${GREEN}Using pre-collected information${NC}"
    echo ""
    sleep 1
    echo -e "${YELLOW}We will need your required SQL root password${NC}"
    sleep 1
    sqlpasswrd=$(ask_twice "What is your required SQL root password" "true")
    echo -e "\n"
    sleep 1

    echo -e "${YELLOW}Updating system packages...${NC}"
    sleep 2
    sudo apt update
    sudo apt upgrade -y
    echo -e "${GREEN}System packages updated.${NC}"
    sleep 2

    echo -e "${YELLOW}Installing preliminary package requirements${NC}"
    sleep 3
    sudo apt install software-properties-common git curl whiptail cron -y

    os_version=$(lsb_release -rs)
    if [[ "$DISTRO" == "Ubuntu" && "$os_version" == "24.04" ]]; then
        echo "📦 Installing Supervisor and creating default config..."
        sudo apt update
        sudo apt install -y supervisor

        if [ ! -f /etc/supervisor/supervisord.conf ]; then
          sudo tee /etc/supervisor/supervisord.conf > /dev/null <<'EOF'
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700
chown="$USER":"$USER"

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
EOF
        fi

        sudo systemctl enable supervisor
        sudo systemctl restart supervisor
    fi

    echo -e "${YELLOW}Installing python environment manager and other requirements...${NC}"
    sleep 2

    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    py_major=$(echo "$py_version" | cut -d '.' -f 1)
    py_minor=$(echo "$py_version" | cut -d '.' -f 2)

    required_python_minor=10
    required_python_label="3.10"
    required_python_full="3.10.11"

    if [[ "$bench_version" == "version-16" ]]; then
        required_python_minor=14
        required_python_label="3.14"
        required_python_full="3.14.0"
    fi

    if [[ -z "$py_version" ]] || [[ "$py_major" -lt 3 ]] || [[ "$py_major" -eq 3 && "$py_minor" -lt "$required_python_minor" ]]; then
        echo -e "${LIGHT_BLUE}It appears this instance does not meet the minimum Python version required for ERPNext ${version_choice} (Python${required_python_label})...${NC}"
        sleep 2 
        echo -e "${YELLOW}Not to worry, we will sort it out for you${NC}"
        sleep 4
        echo -e "${YELLOW}Installing Python ${required_python_label}+...${NC}"
        sleep 2

        sudo apt -qq install build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
            libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget libbz2-dev -y && \
        wget https://www.python.org/ftp/python/${required_python_full}/Python-${required_python_full}.tgz && \
        tar -xf Python-${required_python_full}.tgz && \
        cd Python-${required_python_full} && \
        ./configure --prefix=/usr/local --enable-optimizations --enable-shared LDFLAGS="-Wl,-rpath /usr/local/lib" && \
        make -j "$(nproc)" && \
        sudo make altinstall && \
        cd .. && \
        sudo rm -rf Python-${required_python_full} && \
        sudo rm Python-${required_python_full}.tgz && \
        pip3."${required_python_minor}" install --user --upgrade pip && \
        echo -e "${GREEN}Python${required_python_label} installation successful!${NC}"
        sleep 2
    fi

    echo -e "\n"
    echo -e "${YELLOW}Installing additional Python packages and Redis Server${NC}"
    sleep 2
    sudo apt install git python3-dev python3-setuptools python3-venv python3-pip redis-server -y

    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}Unsupported architecture: $arch${NC}"; exit 1 ;;
    esac

    sudo apt install fontconfig libxrender1 xfonts-75dpi xfonts-base -y

    wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_"$arch".deb && \
    sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_"$arch".deb || true && \
    sudo cp /usr/local/bin/wkhtmlto* /usr/bin/ && \
    sudo chmod a+x /usr/bin/wk* && \
    sudo rm wkhtmltox_0.12.6.1-2.jammy_"$arch".deb && \
    sudo apt --fix-broken install -y && \
    sudo apt install fontconfig xvfb libfontconfig xfonts-base xfonts-75dpi libxrender1 -y

    echo -e "${GREEN}Done!${NC}"
    sleep 1
    echo -e "\n"

    echo -e "${YELLOW}Now installing MariaDB and other necessary packages...${NC}"
    sleep 2
    sudo apt install mariadb-server mariadb-client -y

    echo -e "${YELLOW}Installing MySQL/MariaDB development libraries and pkg-config...${NC}"
    sleep 1
    sudo apt install pkg-config default-libmysqlclient-dev -y

    echo -e "${GREEN}MariaDB and development packages have been installed successfully.${NC}"
    sleep 2

    MARKER_FILE=~/.mysql_configured.marker
    if [ ! -f "$MARKER_FILE" ]; then
        echo -e "${YELLOW}Now we'll go ahead to apply MariaDB security settings...${NC}"
        sleep 2

        sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$sqlpasswrd';"
        sudo mysql -u root -p"$sqlpasswrd" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$sqlpasswrd';"
        sudo mysql -u root -p"$sqlpasswrd" -e "DELETE FROM mysql.user WHERE User='';"
        sudo mysql -u root -p"$sqlpasswrd" -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
        sudo mysql -u root -p"$sqlpasswrd" -e "FLUSH PRIVILEGES;"

        echo -e "${YELLOW}...And add some settings to /etc/mysql/my.cnf:${NC}"
        sleep 2

        sudo bash -c 'cat << EOF >> /etc/mysql/my.cnf
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF'

        sudo service mysql restart

        touch "$MARKER_FILE"
        echo -e "${GREEN}MariaDB settings done!${NC}"
        echo -e "\n"
        sleep 1
    fi

    echo -e "${YELLOW}Now to install NVM, Node, npm and yarn${NC}"
    sleep 2

    echo -e "${YELLOW}Installing NVM and Node.js for user: $INSTALL_USER${NC}"
    
    # Install NVM for the target user
    sudo -u "$INSTALL_USER" bash -c 'curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash'

    nvm_init='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    # Add NVM to target user's profile
    sudo -u "$INSTALL_USER" bash -c "grep -qxF 'export NVM_DIR=\"$HOME/.nvm\"' ~/.profile 2>/dev/null || echo '$nvm_init' >> ~/.profile"
    sudo -u "$INSTALL_USER" bash -c "grep -qxF 'export NVM_DIR=\"$HOME/.nvm\"' ~/.bashrc 2>/dev/null || echo '$nvm_init' >> ~/.bashrc"

    # Set up NVM environment for target user
    sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    # Install Node.js for the target user based on version
    if [[ "$bench_version" == "version-16" ]]; then
        sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install 24 && nvm alias default 24'
        node_version="24"
    elif [[ "$DISTRO" == "Ubuntu" && "$os_version" == "24.04" ]]; then
        sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install 20 && nvm alias default 20'
        node_version="20"
    elif [[ "$bench_version" == "version-15" || "$bench_version" == "develop" ]]; then
        sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install 18 && nvm alias default 18'
        node_version="18"
    else
        sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install 16 && nvm alias default 16'
        node_version="16"
    fi

    # Install yarn for the target user AND system-wide
    # Install for target user
    sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && npm install -g yarn@1.22.19'
    
    # Also install system-wide yarn for sudo operations
    sudo npm install -g yarn@1.22.19 || echo "System-wide yarn installation skipped"

    echo -e "${GREEN}nvm and Node (v${node_version}) have been installed and aliased as default.${NC}"
    # Check yarn version
    if sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && yarn --version' 2>/dev/null; then
        yarn_version=$(sudo -u "$INSTALL_USER" bash -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && yarn --version')
        echo -e "${GREEN}Yarn v$yarn_version (Classic) installed globally for $INSTALL_USER.${NC}"
    else
        echo -e "${YELLOW}Yarn not found for $INSTALL_USER, using system-wide yarn.${NC}"
    fi
    sleep 2

    if [[ -z "$py_version" ]] || [[ "$py_major" -lt 3 ]] || [[ "$py_major" -eq 3 && "$py_minor" -lt "$required_python_minor" ]]; then
        echo -e "${YELLOW}Setting up Python virtual environment for $INSTALL_USER...${NC}"
        sudo -u "$INSTALL_USER" bash -c "
            if [[ ! -d '$INSTALL_HOME/venv' ]]; then
                python3.${required_python_minor} -m venv '$INSTALL_HOME/venv'
            fi
        "
        echo -e "${GREEN}✓ Python virtual environment created for $INSTALL_USER${NC}"
    fi

    echo -e "${YELLOW}Now let's install bench${NC}"
    sleep 2

    externally_managed_file=$(find /usr/lib/python3.*/EXTERNALLY-MANAGED 2>/dev/null || true)
    if [[ -n "$externally_managed_file" ]]; then
        sudo python3 -m pip config --global set global.break-system-packages true
    fi

    sudo apt install python3-pip -y
    sudo pip3 install frappe-bench

    echo -e "${YELLOW}Initializing bench: $bench_name${NC}"
    echo -e "${LIGHT_BLUE}Using pre-collected bench name${NC}"
    
    # Initialize bench with proper environment for the target user
    echo -e "${YELLOW}Creating bench with Node.js and Python environment for $INSTALL_USER...${NC}"
    sudo -u "$INSTALL_USER" bash -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        [ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
        nvm use default
        
        # Activate virtual environment if it exists
        if [[ -f '$INSTALL_HOME/venv/bin/activate' ]]; then
            source '$INSTALL_HOME/venv/bin/activate'
        fi
        
        cd '$INSTALL_HOME'
        bench init '$bench_name' --version '$bench_version' --verbose
    "
    echo -e "${GREEN}Bench installation complete!${NC}"
    sleep 1

    echo -e "${YELLOW}Preparing site: $site_name${NC}"
    echo -e "${GREEN}Using pre-collected passwords${NC}"
    sleep 2
    echo -e "${YELLOW}Setting up your site. This might take a few minutes. Please wait...${NC}"
    sleep 1

    # Set permissions for the installation
    sudo chmod -R o+rx "$INSTALL_HOME"
    
    # We'll work from the current directory but use full paths
    echo -e "${LIGHT_BLUE}Working from current directory with full paths to $INSTALL_HOME${NC}"

    # Create new site as the selected user
    sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench new-site '$site_name' --db-root-username root --db-root-password '$sqlpasswrd' --admin-password '$adminpasswrd'"

    if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
        echo -e "${YELLOW}Starting Redis instances for $bench_version (queue, cache, and socketio)...${NC}"
        sleep 1
        redis-server --port 11000 --daemonize yes --bind 127.0.0.1
        redis-server --port 12000 --daemonize yes --bind 127.0.0.1
        redis-server --port 13000 --daemonize yes --bind 127.0.0.1
        echo -e "${GREEN}Redis instances started for $bench_version.${NC}"
        sleep 1
    fi

    echo -e "${YELLOW}Installing ERPNext application...${NC}"
    sleep 2
    sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench get-app erpnext --branch '$bench_version'" && \
    sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app erpnext" || {
        echo -e "${RED}Failed to install ERPNext. Continuing with setup...${NC}"
    }
    echo -e "${GREEN}✓ ERPNext installation completed${NC}"
    sleep 1

    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    bench_module_dir=$(python3 -c "import bench, os; print(os.path.dirname(bench.__file__))" 2>/dev/null || true)
    playbook_file=""

    if [[ -n "$bench_module_dir" ]]; then
        playbook_file="$bench_module_dir/playbooks/roles/mariadb/tasks/main.yml"
    fi

    if [[ -z "$playbook_file" || ! -f "$playbook_file" ]]; then
        playbook_file="/usr/local/lib/python${python_version}/dist-packages/bench/playbooks/roles/mariadb/tasks/main.yml"
        if [[ ! -f "$playbook_file" ]]; then
            playbook_file="/usr/local/lib/python${python_version}/site-packages/bench/playbooks/roles/mariadb/tasks/main.yml"
        fi
    fi

    if [[ -f "$playbook_file" ]]; then
        sudo sed -i 's/- include: /- include_tasks: /g' "$playbook_file"
    else
        echo -e "${YELLOW}Could not locate bench MariaDB playbook to patch include_tasks. Skipping.${NC}"
    fi

    echo -e "${YELLOW}Starting production setup...${NC}"
    sleep 2
            echo -e "${YELLOW}Installing packages and dependencies for Production...${NC}"
            sleep 2

            if [[ "$DISTRO" == "Ubuntu" && "$os_version" == "24.04" ]]; then
                echo "🔧 Patching Ansible nginx vhosts condition..."
                sudo sed -i 's/when: nginx_vhosts/when: nginx_vhosts | length > 0/' \
                /usr/local/lib/python3.12/dist-packages/bench/playbooks/roles/nginx/tasks/vhosts.yml

                echo "🧹 Fixing nginx PID permissions before reload..."

                if ! dpkg -s nginx >/dev/null 2>&1; then
                  echo "📦 Nginx not found. Installing it now..."
                  sudo apt update && sudo apt install -y nginx
                fi

                sudo systemctl stop nginx 2>/dev/null || true
                sudo rm -f /var/run/nginx.pid || true
                sudo chown root:root /var/run
                sudo rm -f /etc/nginx/sites-enabled/default || true
                sudo systemctl start nginx
                sudo nginx -t || true
            fi
            
            sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && yes | bench setup production '$INSTALL_USER'" && \
            echo -e "${YELLOW}Applying necessary permissions to supervisor...${NC}"
            sleep 1

            FILE="/etc/supervisor/supervisord.conf"
            SEARCH_PATTERN="chown=$INSTALL_USER:$INSTALL_USER"

            if grep -q "$SEARCH_PATTERN" "$FILE"; then
                echo -e "${YELLOW}User ownership already exists for supervisord. Updating it...${NC}"
                sudo sed -i "/chown=.*/c $SEARCH_PATTERN" "$FILE"
            else
                echo -e "${YELLOW}User ownership does not exist for supervisor. Adding it...${NC}"
                sudo sed -i "5a $SEARCH_PATTERN" "$FILE"
            fi

echo -e "${YELLOW}Configuring production setup...${NC}"
            sleep 1
            
            sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && yes | bench setup production '$INSTALL_USER'"
            
            echo -e "${YELLOW}Enabling Scheduler...${NC}"
            sleep 1

            sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' scheduler enable" && \
            sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' scheduler resume"

            if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
                echo -e "${YELLOW}Setting up Socketio, Redis and Supervisor for $bench_version...${NC}"
                sleep 1
                echo -e "${YELLOW}Setting up Socketio, Redis and Supervisor for $bench_version...${NC}"
                sleep 1
                
                sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench setup socketio"
                sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && echo 'y' | bench setup supervisor"
                sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench setup redis"
                sudo supervisorctl reload
            fi

            echo -e "${YELLOW}Restarting bench to apply all changes and optimizing environment permissions.${NC}"
            sleep 1

            sudo chmod 755 "$INSTALL_HOME"
            
            echo -e "${YELLOW}Configuring Redis services...${NC}"
            sudo systemctl restart redis-server
            sleep 2
            
            # Enhanced service restart with better error handling
            echo -e "${YELLOW}Restarting all services with enhanced error handling...${NC}"
            
            # Stop all services first
            sudo supervisorctl stop all 2>/dev/null || true
            sleep 2
            
            # Start Redis services first
            if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
                echo -e "${LIGHT_BLUE}Starting Redis services...${NC}"
                sudo supervisorctl start redis-cache 2>/dev/null || true
                sudo supervisorctl start redis-queue 2>/dev/null || true
                sudo supervisorctl start redis-socketio 2>/dev/null || true
                sleep 2
            fi
            
            # Start remaining services
            echo -e "${LIGHT_BLUE}Starting remaining services...${NC}"
            sudo supervisorctl start all 2>/dev/null || true
            sleep 3
            
            # Check service status
            echo -e "${LIGHT_BLUE}Checking service status...${NC}"
            sudo supervisorctl status
            
            if ! sudo supervisorctl status | grep -q "RUNNING"; then
                echo -e "${YELLOW}Warning: Some services may not be running properly.${NC}"
                echo -e "${YELLOW}You can check status with: sudo supervisorctl status${NC}"
                echo -e "${YELLOW}You can restart services with: sudo supervisorctl restart all${NC}"
            else
                echo -e "${GREEN}✓ All services are running properly!${NC}"
            fi
            sleep 3

            printf "${GREEN}Production setup complete! "
            printf '\xF0\x9F\x8E\x86'
            printf "${NC}\n"
            sleep 3

            #
            # ─── ADDITIONAL APPS INSTALL SECTION ────────────────────────────────────────
            #
echo -e "${YELLOW}Checking for additional Frappe apps...${NC}"
    
    echo -e "${YELLOW}⚠️  Additional Apps Installation${NC}"
    echo -e "${LIGHT_BLUE}Note: App compatibility may vary. Some apps might fail to install${NC}"
    echo -e "${LIGHT_BLUE}due to version mismatches or missing dependencies.${NC}"
    echo ""
    echo -e "${GREEN}Apps courtesy of awesome-frappe by Gavin D'Souza (@gavindsouza)${NC}"
    echo -e "${GREEN}Repository: https://github.com/gavindsouza/awesome-frappe${NC}"
    echo ""
    echo -e "${GREEN}Proceeding with additional apps installation...${NC}"
    
    # Skip additional apps for now (can be enabled later by user choice)
    echo -e "${YELLOW}ℹ Skipping additional apps for faster initial installation${NC}"
    echo -e "${LIGHT_BLUE}You can install apps later using: bench get-app <app-name>${NC}"
                    echo ""
                    echo -e "${YELLOW}⚠️  Additional Apps Installation${NC}"
                    echo -e "${LIGHT_BLUE}Note: App compatibility may vary. Some apps might fail to install${NC}"
                    echo -e "${LIGHT_BLUE}due to version mismatches or missing dependencies.${NC}"
                    echo ""
                    echo -e "${GREEN}Apps courtesy of awesome-frappe by Gavin D'Souza (@gavindsouza)${NC}"
                    echo -e "${GREEN}Repository: https://github.com/gavindsouza/awesome-frappe${NC}"
                    echo ""
                    read -p "Continue with app installation? (yes/no): " apps_confirm
                    apps_confirm=$(echo "$apps_confirm" | tr '[:upper:]' '[:lower:]')
                    
                    if [[ "$apps_confirm" != "yes" && "$apps_confirm" != "y" ]]; then
                        echo -e "${GREEN}Apps installation cancelled.${NC}"
                    else
                        echo -e "${GREEN}Proceeding with additional apps installation...${NC}"
                        echo ""
                        if [[ "$bench_version" == "version-16" ]]; then
                            echo -e "${YELLOW}⚠️  ERPNext v16 caveat:${NC}"
                            echo -e "${YELLOW}Apps not developed by Frappe are not tested on v16 yet. Install at your own risk.${NC}"
                            echo ""
                        fi
                        
                        echo -e "${YELLOW}Fetching available apps from awesome-frappe repository...${NC}"
                    tmp_dir=$(mktemp -d)
                    
                    if ! git clone https://github.com/gavindsouza/awesome-frappe.git "$tmp_dir" --depth 1 2>/dev/null; then
                        echo -e "${RED}Failed to clone awesome-frappe repository. Skipping additional apps installation.${NC}"
                        rm -rf "$tmp_dir"
                    else
                        if [[ ! -f "$tmp_dir/README.md" ]]; then
                            echo -e "${RED}README.md not found in awesome-frappe repository. Skipping additional apps installation.${NC}"
                            rm -rf "$tmp_dir"
                        else
                            mapfile -t raw_entries < <(
                                {
                                    grep -oE '\[([^]]+)\]\(https://github\.com/[^)]*\)' "$tmp_dir/README.md" 2>/dev/null || true
                                    grep -oE '\[([^]]+)\]\(https://frappecloud\.com/marketplace/[^)]*\)' "$tmp_dir/README.md" 2>/dev/null || true
                                    grep -oE '\[([^]]+)\]\(https://frappe\.io/[^)]*\)' "$tmp_dir/README.md" 2>/dev/null || true
                                    
                                    echo "[Frappe HR](https://github.com/frappe/hrms.git)"
                                    echo "[Frappe LMS](https://github.com/frappe/lms.git)"
                                    echo "[Frappe CRM](https://github.com/frappe/crm.git)"
                                    echo "[Frappe Helpdesk](https://github.com/frappe/helpdesk.git)"
                                    echo "[Frappe Builder](https://github.com/frappe/builder.git)"
                                    echo "[Frappe Drive](https://github.com/frappe/drive.git)"
                                    echo "[Frappe Gameplan](https://github.com/frappe/gameplan.git)"
                                } | sort -u
                            )

                            if [ "${#raw_entries[@]}" -eq 0 ]; then
                                echo -e "${RED}No GitHub repository links found in awesome-frappe README. Skipping.${NC}"
                                rm -rf "$tmp_dir"
                            else
                                declare -a display_names=()
                                declare -a repo_names=()
                                declare -a url_array=()
                                
                                if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
                                    echo -e "${YELLOW}Checking app compatibility with $bench_version...${NC}"
                                    echo -e "${LIGHT_BLUE}This may take a moment, please wait...${NC}"
                                    
                                    total_apps=${#raw_entries[@]}
                                    current_app=0
                                    compatible_count=0
                                    
                                    for entry in "${raw_entries[@]}"; do
                                        current_app=$((current_app + 1))
                                        
                                        echo -ne "\r${LIGHT_BLUE}Progress: $current_app/$total_apps apps checked...${NC}"
                                        
                                        display_name=$(echo "$entry" | sed -E 's/\[([^]]+)\]\(.*/\1/')
                                        url=$(echo "$entry" | sed -E 's/.*\(([^)]+)\).*/\1/')
                                        
                                        repo_url=""
                                        repo_name=""
                                        
                                        if [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
                                            repo_url="$url"
                                            if [[ ! "$repo_url" =~ \.git$ ]]; then
                                                repo_url="${repo_url}.git"
                                            fi
                                            repo_name=$(basename "$repo_url" .git)
                                        elif [[ "$url" =~ ^https://frappecloud\.com/marketplace/ ]] || [[ "$url" =~ ^https://github\.com/frappe/ ]]; then
                                            case "$display_name" in
                                                "Frappe HR"|"HRMS")
                                                    repo_url="https://github.com/frappe/hrms.git"
                                                    repo_name="hrms"
                                                    ;;
                                                "Frappe LMS")
                                                    repo_url="https://github.com/frappe/lms.git"
                                                    repo_name="lms"
                                                    ;;
                                                "Frappe CRM")
                                                    repo_url="https://github.com/frappe/crm.git"
                                                    repo_name="crm"
                                                    ;;
                                                "Frappe Helpdesk")
                                                    repo_url="https://github.com/frappe/helpdesk.git"
                                                    repo_name="helpdesk"
                                                    ;;
                                                "Frappe Builder")
                                                    repo_url="https://github.com/frappe/builder.git"
                                                    repo_name="builder"
                                                    ;;
                                                "Frappe Drive")
                                                    repo_url="https://github.com/frappe/drive.git"
                                                    repo_name="drive"
                                                    ;;
                                                "Frappe Gameplan")
                                                    repo_url="https://github.com/frappe/gameplan.git"
                                                    repo_name="gameplan"
                                                    ;;
                                                *)
                                                    if [[ "$url" =~ ^https://github\.com/ ]]; then
                                                        repo_url="$url"
                                                        if [[ ! "$repo_url" =~ \.git$ ]]; then
                                                            repo_url="${repo_url}.git"
                                                        fi
                                                        repo_name=$(basename "$repo_url" .git)
                                                    else
                                                        continue
                                                    fi
                                                    ;;
                                            esac
                                        else
                                            continue
                                        fi
                                        
                                        if [[ "$repo_name" == ".git" || "$repo_name" == "" ]]; then
                                            continue
                                        fi
                                        
                                        repo_check_dir=$(mktemp -d)
                                        
                                        if git clone "$repo_url" "$repo_check_dir" --depth 1 --quiet 2>/dev/null; then
                                            if [[ -f "$repo_check_dir/pyproject.toml" ]]; then
                                                display_names+=("$display_name")
                                                repo_names+=("$repo_name")
                                                url_array+=("$repo_url")
                                                compatible_count=$((compatible_count + 1))
                                            fi
                                        fi
                                        
                                        rm -rf "$repo_check_dir"
                                    done
                                    
                                    echo -e "\r${GREEN}✓ Compatibility check complete: $compatible_count/$total_apps apps are compatible with $bench_version${NC}"
                                    
                                else
                                    echo -e "${YELLOW}Processing available apps for $bench_version...${NC}"
                                    
                                    for entry in "${raw_entries[@]}"; do
                                        display_name=$(echo "$entry" | sed -E 's/\[([^]]+)\]\(.*/\1/')
                                        url=$(echo "$entry" | sed -E 's/.*\(([^)]+)\).*/\1/')
                                        
                                        repo_url=""
                                        repo_name=""
                                        
                                        if [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
                                            repo_url="$url"
                                            if [[ ! "$repo_url" =~ \.git$ ]]; then
                                                repo_url="${repo_url}.git"
                                            fi
                                            repo_name=$(basename "$repo_url" .git)
                                        elif [[ "$url" =~ ^https://frappecloud\.com/marketplace/ ]] || [[ "$url" =~ ^https://github\.com/frappe/ ]]; then
                                            case "$display_name" in
                                                "Frappe HR"|"HRMS")
                                                    repo_url="https://github.com/frappe/hrms.git"
                                                    repo_name="hrms"
                                                    ;;
                                                "Frappe LMS")
                                                    repo_url="https://github.com/frappe/lms.git"
                                                    repo_name="lms"
                                                    ;;
                                                "Frappe CRM")
                                                    repo_url="https://github.com/frappe/crm.git"
                                                    repo_name="crm"
                                                    ;;
                                                "Frappe Helpdesk")
                                                    repo_url="https://github.com/frappe/helpdesk.git"
                                                    repo_name="helpdesk"
                                                    ;;
                                                "Frappe Builder")
                                                    repo_url="https://github.com/frappe/builder.git"
                                                    repo_name="builder"
                                                    ;;
                                                "Frappe Drive")
                                                    repo_url="https://github.com/frappe/drive.git"
                                                    repo_name="drive"
                                                    ;;
                                                "Frappe Gameplan")
                                                    repo_url="https://github.com/frappe/gameplan.git"
                                                    repo_name="gameplan"
                                                    ;;
                                                *)
                                                    if [[ "$url" =~ ^https://github\.com/ ]]; then
                                                        repo_url="$url"
                                                        if [[ ! "$repo_url" =~ \.git$ ]]; then
                                                            repo_url="${repo_url}.git"
                                                        fi
                                                        repo_name=$(basename "$repo_url" .git)
                                                    else
                                                        continue
                                                    fi
                                                    ;;
                                            esac
                                        else
                                            continue
                                        fi
                                        
                                        if [[ "$repo_name" == ".git" || "$repo_name" == "" ]]; then
                                            continue
                                        fi
                                        
                                        display_names+=("$display_name")
                                        repo_names+=("$repo_name")
                                        url_array+=("$repo_url")
                                    done
                                    
                                    echo -e "${GREEN}✓ Found ${#display_names[@]} apps available for $bench_version${NC}"
                                fi

                                declare -a unique_display_names=()
                                declare -a unique_repo_names=()
                                declare -a unique_urls=()
                                declare -A seen_repos=()
                                
                                for i in "${!repo_names[@]}"; do
                                    if [[ -z "${seen_repos[${repo_names[$i]}]}" ]]; then
                                        seen_repos["${repo_names[$i]}"]=1
                                        unique_display_names+=("${display_names[$i]}")
                                        unique_repo_names+=("${repo_names[$i]}")
                                        unique_urls+=("${url_array[$i]}")
                                    fi
                                done

                                declare -a sorted_indices=()
                                readarray -t sorted_indices < <(
                                    for i in "${!unique_display_names[@]}"; do
                                        echo "$i ${unique_display_names[$i]}"
                                    done | sort -k2 | cut -d' ' -f1
                                )

                                declare -a final_display_names=()
                                declare -a final_repo_names=()
                                declare -a final_urls=()
                                
                                for i in "${sorted_indices[@]}"; do
                                    final_display_names+=("${unique_display_names[$i]}")
                                    final_repo_names+=("${unique_repo_names[$i]}")
                                    final_urls+=("${unique_urls[$i]}")
                                done

                                display_names=("${final_display_names[@]}")
                                repo_names=("${final_repo_names[@]}")
                                url_array=("${final_urls[@]}")

                                if [ "${#display_names[@]}" -eq 0 ]; then
                                    if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
                                        echo -e "${RED}No apps with pyproject.toml found that are compatible with $bench_version.${NC}"
                                        echo -e "${YELLOW}ERPNext v15/v16/develop requires apps to have pyproject.toml files.${NC}"
                                    else
                                        echo -e "${RED}No valid Frappe apps found in awesome-frappe README.${NC}"
                                    fi
                                    rm -rf "$tmp_dir"
                                else
                                    if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
                                        echo -e "${GREEN}Found ${#display_names[@]} compatible apps with pyproject.toml for $bench_version.${NC}"
                                    else
                                        echo -e "${GREEN}Found ${#display_names[@]} available apps for $bench_version.${NC}"
                                    fi

                                    terminal_height=$(tput lines 2>/dev/null || echo 24)
                                    terminal_width=$(tput cols 2>/dev/null || echo 80)
                                    
                                    max_dialog_height=$((terminal_height - 4))
                                    max_dialog_width=$((terminal_width - 10))
                                    
                                    max_display_len=0
                                    for name in "${display_names[@]}"; do
                                        if (( ${#name} > 50 )); then
                                            name="${name:0:47}..."
                                        fi
                                        if (( ${#name} > max_display_len )); then
                                            max_display_len=${#name}
                                        fi
                                    done
                                    
                                    dialog_width=$((max_display_len + 25))
                                    if (( dialog_width < 60 )); then
                                        dialog_width=60
                                    elif (( dialog_width > max_dialog_width )); then
                                        dialog_width=$max_dialog_width
                                    fi
                                    
                                    item_count=${#display_names[@]}
                                    dialog_height=$((item_count + 8))
                                    if (( dialog_height > max_dialog_height )); then
                                        dialog_height=$max_dialog_height
                                    fi

                                    OPTIONS=()
                                    for i in "${!display_names[@]}"; do
                                        display_name="${display_names[$i]}"
                                        
                                        if (( ${#display_name} > 50 )); then
                                            display_name="${display_name:0:47}..."
                                        fi
                                        
                                        OPTIONS+=("$display_name" "" OFF)
                                    done

                                    CHOICES=$(whiptail --title "Additional Frappe Apps (${#display_names[@]} available)" \
                                        --checklist "Choose apps to install (Space=toggle, Enter=confirm):" \
                                        "$dialog_height" "$dialog_width" "$((dialog_height - 8))" \
                                        "${OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
                                        echo -e "${RED}No apps selected or dialog cancelled. Skipping additional apps installation.${NC}"
                                        rm -rf "$tmp_dir"
                                    }

                                    if [ -z "$CHOICES" ]; then
                                        echo -e "${RED}No apps selected. Skipping additional apps installation.${NC}"
                                        rm -rf "$tmp_dir"
                                    else
                                        eval "selected_display_names=($CHOICES)"

                                        echo -e "${GREEN}Selected ${#selected_display_names[@]} apps for installation.${NC}"

                                        installation_errors=()
                                        successful_installations=()
                                        
                                        for selected_display_name in "${selected_display_names[@]}"; do
                                            selected_repo=""
                                            selected_url=""
                                            
                                            for idx in "${!display_names[@]}"; do
                                                if [[ "${display_names[$idx]}" == "$selected_display_name" ]]; then
                                                    selected_repo="${repo_names[$idx]}"
                                                    selected_url="${url_array[$idx]}"
                                                    break
                                                fi
                                            done

                                            if [[ -z "$selected_url" ]]; then
                                                echo -e "${RED}Could not find URL for \"$selected_display_name\". Skipping.${NC}"
                                                installation_errors+=("$selected_display_name: URL not found")
                                                continue
                                            fi

                                            echo -e "${YELLOW}Installing \"$selected_display_name\" ($selected_repo)...${NC}"
                                            echo -e "${LIGHT_BLUE}Repository: $selected_url${NC}"

                                            echo -e "${YELLOW}Step 1/2: Downloading app...${NC}"
                                            
                                            echo -e "${LIGHT_BLUE}📄 Detecting optimal branch for $selected_repo...${NC}"
                                            best_branch=$(detect_best_branch "$selected_url" "$bench_version" "$selected_repo")
                                            
                                            if [[ -z "$best_branch" ]]; then
                                                echo -e "${RED}⚠ Could not detect any branches for $selected_repo. Skipping.${NC}"
                                                installation_errors+=("$selected_display_name: No branches detected")
                                                continue
                                            fi
                                            
                                            echo -e "${GREEN}📌 Will install using branch: $best_branch${NC}"
                                            echo ""
                                            
                                            download_success=false
                                            
                                            echo -e "${YELLOW}📽 Downloading from branch '$best_branch'...${NC}"
                                            if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench get-app '$selected_url' --branch '$best_branch' --skip-assets" 2>/tmp/bench_error_$.log; then
                                                download_success=true
                                                echo -e "${GREEN}✅ Successfully downloaded \"$selected_display_name\" from branch '$best_branch'.${NC}"
                                            else
                                                echo -e "${RED}❌ Failed to download from branch '$best_branch'.${NC}"
                                                if [[ -f /tmp/bench_error_$.log ]]; then
                                                    echo -e "${LIGHT_BLUE}Error details:${NC}"
                                                    tail -2 /tmp/bench_error_$.log
                                                fi
                                            fi
                                            
                                            if [ "$download_success" = true ]; then
                                                echo -e "${YELLOW}Step 2/2: Installing to site...${NC}"
                                                app_installed=false
                                                
                                                app_dir="apps/$selected_repo"
                                                setup_py_path="$app_dir/setup.py"
                                                
                                                if [[ -f "$setup_py_path" ]]; then
                                                    extracted_app_name=$(extract_app_name_from_setup "$setup_py_path")
                                                    
                                                    if [[ -n "$extracted_app_name" ]]; then
                                                        echo -e "${LIGHT_BLUE}Found app name in setup.py: \"$extracted_app_name\"${NC}"
                                                        if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app '$extracted_app_name'" 2>/dev/null; then
                                                            echo -e "${GREEN}✓ Successfully installed using setup.py name.${NC}"
                                                            successful_installations+=("$selected_display_name (branch: $best_branch)")
                                                            app_installed=true
                                                        else
                                                            echo -e "${YELLOW}⚠ Setup.py name failed, trying alternatives...${NC}"
                                                        fi
                                                    else
                                                        echo -e "${YELLOW}⚠ Could not extract name from setup.py, trying alternatives...${NC}"
                                                    fi
                                                fi
                                                
                                                if [[ "$app_installed" == false ]]; then
                                                    echo -e "${LIGHT_BLUE}Trying repo name: \"$selected_repo\"${NC}"
                                                    if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app '$selected_repo'" 2>/dev/null; then
                                                        echo -e "${GREEN}✓ Successfully installed using repo name.${NC}"
                                                        successful_installations+=("$selected_display_name (branch: $best_branch)")
                                                        app_installed=true
                                                    fi
                                                fi
                                                
                                                if [[ "$app_installed" == false ]]; then
                                                    transformed_name=$(echo "$selected_repo" | sed -E 's/^(frappe[-_]?|erpnext[-_]?)//' | tr '-' '_' | tr '[:upper:]' '[:lower:]')
                                                    
                                                    if [[ "$transformed_name" != "$selected_repo" ]]; then
                                                        echo -e "${LIGHT_BLUE}Trying transformed name: \"$transformed_name\"${NC}"
                                                        if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app '$transformed_name'" 2>/dev/null; then
                                                            echo -e "${GREEN}✓ Successfully installed using transformed name.${NC}"
                                                            successful_installations+=("$selected_display_name (branch: $best_branch)")
                                                            app_installed=true
                                                        fi
                                                    fi
                                                fi
                                                
                                                if [[ "$app_installed" == false ]]; then
                                                    lowercase_name=$(echo "$selected_repo" | tr '[:upper:]' '[:lower:]')
                                                    if [[ "$lowercase_name" != "$selected_repo" ]]; then
                                                        echo -e "${LIGHT_BLUE}Trying lowercase: \"$lowercase_name\"${NC}"
                                                        if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app '$lowercase_name'" 2>/dev/null; then
                                                            echo -e "${GREEN}✓ Successfully installed using lowercase name.${NC}"
                                                            successful_installations+=("$selected_display_name (branch: $best_branch)")
                                                            app_installed=true
                                                        fi
                                                    fi
                                                fi
                                                
                                                if [[ "$app_installed" == false && -d "$app_dir" ]]; then
                                                    for subdir in "$app_dir"/*/; do
                                                        if [[ -d "$subdir" && -f "$subdir/__init__.py" ]]; then
                                                            potential_app_name=$(basename "$subdir")
                                                            if [[ "$potential_app_name" != "tests" && "$potential_app_name" != "docs" && "$potential_app_name" != "__pycache__" ]]; then
                                                                echo -e "${LIGHT_BLUE}Trying directory name: \"$potential_app_name\"${NC}"
                                                                if sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench --site '$site_name' install-app '$potential_app_name'" 2>/dev/null; then
                                                                    echo -e "${GREEN}✓ Successfully installed using directory name.${NC}"
                                                                    successful_installations+=("$selected_display_name (branch: $best_branch)")
                                                                    app_installed=true
                                                                    break
                                                                fi
                                                            fi
                                                        fi
                                                    done
                                                fi
                                                
                                                if [[ "$app_installed" == false ]]; then
                                                    echo -e "${RED}✗ Failed to install \"$selected_display_name\" after trying all strategies.${NC}"
                                                    echo -e "${YELLOW}This app may have compatibility issues with ERPNext $bench_version or missing dependencies.${NC}"
                                                    installation_errors+=("$selected_display_name (branch: $best_branch): Installation failed (compatibility/dependency issues)")
                                                fi
                                                
                                                rm -f /tmp/bench_error_$.log
                                            else
                                                if [[ -d "apps/$selected_repo" ]]; then
                                                    echo -e "${YELLOW}⚠ App was cloned but failed during pip install phase.${NC}"
                                                    echo -e "${RED}✗ \"$selected_display_name\" has dependency/compatibility issues with ERPNext $bench_version.${NC}"
                                                    
                                                    if [[ -f /tmp/bench_error_$.log ]]; then
                                                        echo -e "${LIGHT_BLUE}Error details:${NC}"
                                                        tail -3 /tmp/bench_error_$.log | grep -E "(ERROR|Failed|returned non-zero)" || echo "Check app requirements and compatibility."
                                                    fi
                                                    
                                                    installation_errors+=("$selected_display_name (branch: $best_branch): Dependency/compatibility issues")
                                                else
                                                    echo -e "${RED}✗ Failed to clone \"$selected_display_name\" from repository.${NC}"
                                                    installation_errors+=("$selected_display_name (branch: $best_branch): Git clone failed")
                                                fi
                                                
                                                rm -f /tmp/bench_error_$.log
                                            fi
                                            
                                            echo -e "\n${LIGHT_BLUE}────────────────────────────────────────${NC}\n"
                                        done

                                        echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
                                        echo -e "${GREEN}║           Installation Summary       ║${NC}"
                                        echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
                                        
                                        if [ "${#successful_installations[@]}" -gt 0 ]; then
                                            echo -e "${GREEN}✓ Successfully installed ${#successful_installations[@]} apps:${NC}"
                                            for app in "${successful_installations[@]}"; do
                                                echo -e "  ${GREEN}✓${NC} $app"
                                            done
                                            echo ""
                                        fi
                                        
                                        if [ "${#installation_errors[@]}" -gt 0 ]; then
                                            echo -e "${RED}✗ Failed to install ${#installation_errors[@]} apps:${NC}"
                                            for error in "${installation_errors[@]}"; do
                                                echo -e "  ${RED}✗${NC} $error"
                                            done
                                            echo ""
                                            echo -e "${YELLOW}Note: Some apps may not be compatible with ERPNext $bench_version${NC}"
                                            echo -e "${YELLOW}or may require specific dependencies that are not installed.${NC}"
                                        fi

                                        rm -rf "$tmp_dir"
                                        
                                        if [ "${#successful_installations[@]}" -gt 0 ]; then
                                            echo -e "${YELLOW}Restarting services to apply changes from new apps...${NC}"
                                            
                                            # Enhanced restart for app installations
                                            sudo supervisorctl stop all 2>/dev/null || true
                                            sleep 2
                                            sudo supervisorctl start all 2>/dev/null || true
                                            sleep 3
                                            
                                            # Verify services are running
                                            if sudo supervisorctl status | grep -q "RUNNING"; then
                                                echo -e "${GREEN}✓ Services restarted successfully after app installation!${NC}"
                                            else
                                                echo -e "${YELLOW}⚠ Some services may need manual restart. Run: sudo supervisorctl restart all${NC}"
                                            fi
                                            
                                            # Additional bench commands to ensure apps are properly loaded
                                            echo -e "${LIGHT_BLUE}Reloading bench configuration...${NC}"
                                            sudo -u "$INSTALL_USER" bash -c "cd '$INSTALL_HOME/$bench_name' && bench build" 2>/dev/null || true
                                            echo -e "${GREEN}✓ Apps installation and service restart completed!${NC}"
                                        fi
                                    fi
                                fi
                            fi
                        fi

            #
            # ─── SSL SECTION ────────────────────────────────────────────────────────────
            #
            if [[ -n "$email_address" ]]; then
                echo -e "${YELLOW}Installing SSL certificate for: $site_name${NC}"
                echo -e "${GREEN}Using pre-collected email: $email_address${NC}"
                sleep 2

                echo -e "${YELLOW}Make sure your domain name is pointed to the IP of this instance and is reachable before proceeding.${NC}"
                sleep 2

                if ! command -v certbot >/dev/null 2>&1; then
                    echo -e "${YELLOW}Installing Certbot...${NC}"
                        if [ "$DISTRO" == "Debian" ]; then
                            echo -e "${YELLOW}Fixing openssl package on Debian...${NC}"
                            sleep 4
                            sudo pip3 uninstall cryptography -y
                            yes | sudo pip3 install pyopenssl==22.0.0 cryptography==36.0.0
                            echo -e "${GREEN}Package fixed${NC}"
                            sleep 2
                        fi

                        sudo apt install snapd -y && \
                        sudo snap install core && \
                        sudo snap refresh core && \
                        sudo snap install --classic certbot && \
                        sudo ln -s /snap/bin/certbot /usr/bin/certbot

                        echo -e "${GREEN}Certbot installed successfully.${NC}"
                    else
                        echo -e "${GREEN}Certbot is already installed. Using pre-collected email: $email_address${NC}"
                        sleep 1
                    fi

                    echo -e "${YELLOW}Obtaining and installing SSL certificate...${NC}"
                    sleep 2
                    sudo certbot --nginx --non-interactive --agree-tos --email "$email_address" -d "$site_name" && {
                        echo -e "${GREEN}SSL certificate installed successfully.${NC}"
                        sleep 2
                    } || {
                        echo -e "${RED}SSL installation failed. You can install it later manually.${NC}"
                    }
            else
                echo -e "${YELLOW}ℹ SSL installation skipped (no email provided)${NC}"
                echo -e "${LIGHT_BLUE}You can install SSL later with: sudo certbot --nginx -d $site_name${NC}"
            fi

            if [[ -z "$py_version" ]] || [[ "$py_major" -lt 3 ]] || [[ "$py_major" -eq 3 && "$py_minor" -lt "$required_python_minor" ]]; then
                deactivate
            fi

            echo -e "${GREEN}--------------------------------------------------------------------------------"
            echo -e "Congratulations! You have successfully installed ERPNext $version_choice."
            echo -e "You can start using your new ERPNext installation by visiting https://$site_name"
            echo -e "(if you have enabled SSL and used a Fully Qualified Domain Name"
            echo -e "during installation) or http://$server_ip to begin."
            echo -e "Install additional apps as required. Visit https://docs.erpnext.com for Documentation."
            echo -e "Enjoy using ERPNext!"
            echo -e "--------------------------------------------------------------------------------${NC}"

# Main menu function
main_installation() {
    clear
    echo -e "${LIGHT_BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${LIGHT_BLUE}║        ERPNext Universal Installation Manager           ║${NC}"
    echo -e "${LIGHT_BLUE}║              Production & Development Ready              ║${NC}"
    echo -e "${LIGHT_BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${YELLOW}Choose installation mode:${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} Single ERPNext Installation ${LIGHT_BLUE}(Recommended for Production)${NC}"
    echo -e "   • Full production setup with SSL support"
    echo -e "   • Complete system configuration"
    echo -e "   • Additional apps installation available"
    echo ""
    echo -e "${YELLOW}2.${NC} Multiple ERPNext Versions ${RED}(Development Only)${NC}"
    echo -e "   • Install multiple versions side-by-side"
    echo -e "   • Different bench folders for each version"
    echo -e "   • NOT recommended for production"
    echo ""
    echo -e "${RED}3.${NC} Exit"
    echo ""
    
    read -p "Enter your choice (1-3): " mode_choice
    
    case $mode_choice in
        1)
            clear
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}     Starting Single ERPNext Installation            ${NC}"
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo ""
            run_single_installation
            ;;
            
        2)
            clear
            echo ""
            echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║     ⚠️  MULTIPLE INSTALLATIONS WARNING ⚠️           ║${NC}"
            echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Multiple installations on the same server:${NC}"
            echo -e "${RED}  • Recommended for DEVELOPMENT ONLY${NC}"
            echo -e "${RED}  • NOT suitable for production environments${NC}"
            echo -e "${RED}  • May cause port conflicts${NC}"
            echo -e "${RED}  • May cause dependency conflicts${NC}"
            echo -e "${RED}  • May cause supervisor conflicts${NC}"
            echo -e "${RED}  • Requires careful manual configuration${NC}"
            echo ""
            echo -e "${LIGHT_BLUE}Best practices for multiple installations:${NC}"
            echo -e "${GREEN}  1. Use DIFFERENT bench folder names (e.g., frappe-bench-13, frappe-bench-14)${NC}"
            echo -e "${GREEN}  2. Use DIFFERENT site names (e.g., site13.local, site14.local)${NC}"
            echo -e "${GREEN}  3. Run each installation SEPARATELY${NC}"
            echo -e "${GREEN}  4. Consider using Docker containers instead${NC}"
            echo ""
            
            read -p "Do you understand these risks and want to continue? (yes/no): " multi_confirm
            multi_confirm=$(echo "$multi_confirm" | tr '[:upper:]' '[:lower:]')
            
            if [[ "$multi_confirm" != "yes" && "$multi_confirm" != "y" ]]; then
                echo -e "${GREEN}Installation cancelled. Good choice!${NC}"
                echo -e "${YELLOW}Consider using option 1 for production installations.${NC}"
                exit 0
            fi
            
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}     Multiple Installations Guide                     ${NC}"
            echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${LIGHT_BLUE}How to install multiple versions:${NC}"
            echo ""
            echo -e "${GREEN}Step 1:${NC} Run this script and select option 1"
            echo -e "${GREEN}Step 2:${NC} Choose your first ERPNext version"
            echo -e "${GREEN}Step 3:${NC} Use a unique bench folder name (e.g., frappe-bench-14)"
            echo -e "${GREEN}Step 4:${NC} Complete the installation"
            echo -e "${GREEN}Step 5:${NC} Run this script AGAIN for the next version"
            echo -e "${GREEN}Step 6:${NC} Use a DIFFERENT bench folder name (e.g., frappe-bench-15)"
            echo ""
            echo -e "${YELLOW}Example for 2 installations:${NC}"
            echo -e "  ${LIGHT_BLUE}Installation 1:${NC}"
            echo -e "    • Version: 14"
            echo -e "    • Bench folder: frappe-bench-14"
            echo -e "    • Site name: site14.local"
            echo ""
            echo -e "  ${LIGHT_BLUE}Installation 2:${NC}"
            echo -e "    • Version: 15"
            echo -e "    • Bench folder: frappe-bench-15"
            echo -e "    • Site name: site15.local"
            echo ""
            echo -e "${RED}IMPORTANT:${NC} Each installation runs through option 1 separately!"
            echo ""
            
            read -p "Press Enter to start your first installation..." pause
            
            clear
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}     Starting First Installation                      ${NC}"
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${YELLOW}Remember to use a unique bench folder name!${NC}"
            echo ""
            
            run_single_installation
            
            echo ""
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}     First Installation Completed!                    ${NC}"
            echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${YELLOW}To install another version:${NC}"
            echo -e "${GREEN}1. Run this script again: ${LIGHT_BLUE}bash multi.sh${NC}"
            echo -e "${GREEN}2. Choose option 1 (Single Installation)${NC}"
            echo -e "${GREEN}3. Select a different ERPNext version${NC}"
            echo -e "${GREEN}4. Use a DIFFERENT bench folder name${NC}"
            echo ""
            echo -e "${LIGHT_BLUE}Your installations:${NC}"
            echo -e "  • Bench: $bench_name"
            echo -e "  • Site: $site_name"
            echo ""
            ;;
            
        3)
            clear
            echo -e "${GREEN}Thank you for using ERPNext Installation Manager!${NC}"
            echo -e "${LIGHT_BLUE}Goodbye!${NC}"
            exit 0
            ;;
            
        *)
            clear
            echo -e "${RED}Invalid choice!${NC}"
            echo -e "${YELLOW}Please run the script again and choose 1, 2, or 3.${NC}"
            exit 1
            ;;
    esac
}

# Run main function
main_installation
