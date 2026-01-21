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

# Store installation configurations
declare -a INSTALLATION_PATHS=()

# Default password for new users
DEFAULT_PASSWORD="ChangeMe123!"

check_os() {
    local os_name=$(lsb_release -is)
    local os_version=$(lsb_release -rs)
    
    echo -e "${YELLOW}Checking OS compatibility...${NC}"
    
    if [[ "$os_name" != "Ubuntu" && "$os_name" != "Debian" ]]; then
        echo -e "${RED}This script only supports Ubuntu and Debian${NC}"
        exit 1
    fi
    
    if [[ "$os_name" == "Ubuntu" ]]; then
        if [[ ! "$os_version" =~ ^(20\.04|22\.04|23\.04|24\.04)$ ]]; then
            echo -e "${RED}Ubuntu $os_version is not supported. Use 20.04, 22.04, 23.04, or 24.04${NC}"
            exit 1
        fi
    elif [[ "$os_name" == "Debian" ]]; then
        if [[ ! "$os_version" =~ ^(9|10|11|12)$ ]]; then
            echo -e "${RED}Debian $os_version is not supported. Use 9, 10, 11, or 12${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ OS: $os_name $os_version is supported${NC}"
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

# Function to perform installation
perform_installation() {
    local install_user="$1"
    local home_dir="$2"
    local bench_version="$3"
    local bench_name="$4"
    local site_name="$5"
    local sqlpasswrd="$6"
    local adminpasswrd="$7"
    local install_erpnext="$8"
    local setup_production="$9"
    
    echo -e "${YELLOW}Starting installation for user: $install_user${NC}"
    echo -e "${LIGHT_BLUE}Version: $bench_version${NC}"
    echo -e "${LIGHT_BLUE}Bench name: $bench_name${NC}"
    
    # Create user if doesn't exist
    create_user_if_not_exists "$install_user"
    
    # Set home directory based on user
    if [[ "$install_user" == "root" ]]; then
        home_dir="/root"
    elif [[ "$install_user" != "$(whoami)" ]]; then
        home_dir="/home/$install_user"
    else
        home_dir="$HOME"
    fi
    
    # Generate unique ports for this installation
    local unique_ports=$(generate_unique_ports "$bench_version" "$bench_name" "$install_user")
    IFS=':' read -r mariadb_port redis_queue redis_cache redis_socketio bench_port <<< "$unique_ports"
    
    echo -e "${GREEN}Assigned ports for this installation:${NC}"
    echo -e "  MariaDB: $mariadb_port"
    echo -e "  Redis Queue: $redis_queue"
    echo -e "  Redis Cache: $redis_cache"
    echo -e "  Redis SocketIO: $redis_socketio"
    echo -e "  Bench: $bench_port"
    
    # Create home directory if it doesn't exist
    sudo mkdir -p "$home_dir"
    sudo chown "$install_user:$install_user" "$home_dir"
    
    echo -e "${YELLOW}Installing system dependencies...${NC}"
    sudo apt update
    sudo apt install -y git curl wget python3-pip python3-dev python3-venv python3-setuptools \
        mariadb-server mariadb-client libmysqlclient-dev redis-server \
        nginx supervisor nodejs npm wkhtmltopdf
    
    # Install bench globally
    sudo pip3 install frappe-bench
    
    # Create a temporary script to run as the target user
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash
set -e

install_user="$1"
bench_version="$2"
bench_name="$3"
site_name="$4"
sqlpasswrd="$5"
adminpasswrd="$6"
install_erpnext="$7"
setup_production="$8"
mariadb_port="$9"
redis_queue="${10}"
redis_cache="${11}"
redis_socketio="${12}"
bench_port="${13}"

echo "Starting installation as user: $(whoami)"
echo "Home directory: $HOME"

# Create bench
cd "$HOME"
bench init "$bench_name" --version "$bench_version" --verbose

cd "$bench_name"

# Create common site config
cat > sites/common_site_config.json << CONFIG
{
    "db_host": "localhost",
    "db_port": $mariadb_port,
    "redis_cache": "redis://localhost:$redis_cache",
    "redis_queue": "redis://localhost:$redis_queue",
    "redis_socketio": "redis://localhost:$redis_socketio",
    "socketio_port": $bench_port
}
CONFIG

# Create site
bench new-site "$site_name" \
    --db-root-username root \
    --db-root-password "$sqlpasswrd" \
    --admin-password "$adminpasswrd" \
    --mariadb-root-password "$sqlpasswrd"

# Start Redis instances
redis-server --port $redis_queue --daemonize yes --bind 127.0.0.1
redis-server --port $redis_cache --daemonize yes --bind 127.0.0.1
redis-server --port $redis_socketio --daemonize yes --bind 127.0.0.1

# Install ERPNext if requested
if [[ "$install_erpnext" == "yes" || "$install_erpnext" == "y" ]]; then
    bench get-app erpnext --branch "$bench_version"
    bench --site "$site_name" install-app erpnext
fi

# Setup production if requested
if [[ "$setup_production" == "yes" || "$setup_production" == "y" ]]; then
    bench setup production "$(whoami)" --yes
    bench --site "$site_name" scheduler enable
    bench --site "$site_name" scheduler resume
    
    if [[ "$bench_version" == "version-15" || "$bench_version" == "version-16" || "$bench_version" == "develop" ]]; then
        bench setup socketio
        bench setup supervisor
        bench setup redis
    fi
fi

echo "Installation complete for $bench_name ($bench_version)"
echo "Access URL: http://localhost:$bench_port"
EOF

    chmod +x "$TEMP_SCRIPT"
    
    # Run the script as the target user
    echo -e "${YELLOW}Running installation script as $install_user...${NC}"
    sudo -u "$install_user" bash "$TEMP_SCRIPT" \
        "$install_user" \
        "$bench_version" \
        "$bench_name" \
        "$site_name" \
        "$sqlpasswrd" \
        "$adminpasswrd" \
        "$install_erpnext" \
        "$setup_production" \
        "$mariadb_port" \
        "$redis_queue" \
        "$redis_cache" \
        "$redis_socketio" \
        "$bench_port"
    
    # Clean up
    rm -f "$TEMP_SCRIPT"
    
    # Fix permissions
    sudo chown -R "$install_user:$install_user" "$home_dir"
    
    echo -e "${GREEN}✓ Installation completed successfully for user $install_user${NC}"
    echo -e "${YELLOW}Bench location: $home_dir/$bench_name${NC}"
    echo -e "${YELLOW}To start bench: sudo -u $install_user bash -c 'cd $home_dir/$bench_name && bench start'${NC}"
}

# Main installation flow
main_installation() {
    clear
    echo -e "${LIGHT_BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${LIGHT_BLUE}║        ERPNext Installation Manager                     ║${NC}"
    echo -e "${LIGHT_BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_os
    
    echo -e "${YELLOW}Choose installation mode:${NC}"
    echo "1. Single ERPNext installation"
    echo "2. Multiple ERPNext versions (same user)"
    echo "3. Exit"
    
    read -p "Enter choice (1-3): " mode_choice
    
    case $mode_choice in
        1)
            echo -e "${YELLOW}Single installation selected${NC}"
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
                1) bench_version="version-13"; version_name="Version 13";;
                2) bench_version="version-14"; version_name="Version 14";;
                3) bench_version="version-15"; version_name="Version 15";;
                4) bench_version="version-16"; version_name="Version 16";;
                5) bench_version="develop"; version_name="Develop";;
                *) echo -e "${RED}Invalid choice${NC}"; exit 1;;
            esac
            
            echo -e "${GREEN}Selected: $version_name${NC}"
            
            read -p "Enter bench name (default: frappe-bench): " bench_name
            bench_name=${bench_name:-frappe-bench}
            
            read -p "Enter site name: " site_name
            sqlpasswrd=$(ask_twice "Enter MariaDB root password" "true")
            adminpasswrd=$(ask_twice "Enter Administrator password" "true")
            
            read -p "Install ERPNext? (yes/no): " install_erpnext
            install_erpnext=$(echo "$install_erpnext" | tr '[:upper:]' '[:lower:]')
            
            read -p "Setup production? (yes/no): " setup_production
            setup_production=$(echo "$setup_production" | tr '[:upper:]' '[:lower:]')
            
            perform_installation "$INSTALL_USER" "$INSTALL_HOME" "$bench_version" "$bench_name" \
                "$site_name" "$sqlpasswrd" "$adminpasswrd" "$install_erpnext" "$setup_production"
            ;;
            
        2)
            echo -e "${YELLOW}Multiple versions installation selected${NC}"
            select_or_create_user || exit 1
            
            echo -e "${GREEN}User: $INSTALL_USER${NC}"
            echo ""
            
            declare -a versions_to_install=()
            declare -a bench_names=()
            
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
            
            echo -e "${GREEN}Will install the following versions for user '$INSTALL_USER':${NC}"
            for i in "${!versions_to_install[@]}"; do
                echo -e "  • ${versions_to_install[$i]} -> ${bench_names[$i]}"
            done
            
            read -p "Continue? (yes/no): " confirm_multiple
            confirm_multiple=$(echo "$confirm_multiple" | tr '[:upper:]' '[:lower:]')
            
            if [[ "$confirm_multiple" != "yes" && "$confirm_multiple" != "y" ]]; then
                echo -e "${RED}Installation cancelled.${NC}"
                exit 0
            fi
            
            # Get common parameters
            echo -e "${YELLOW}Enter common parameters:${NC}"
            sqlpasswrd=$(ask_twice "Enter MariaDB root password" "true")
            adminpasswrd=$(ask_twice "Enter Administrator password" "true")
            
            # Install each version
            for i in "${!versions_to_install[@]}"; do
                echo ""
                echo -e "${LIGHT_BLUE}══════════════════════════════════════════════════════════${NC}"
                echo -e "${LIGHT_BLUE}  Installing ${versions_to_install[$i]} (${bench_names[$i]})  ${NC}"
                echo -e "${LIGHT_BLUE}══════════════════════════════════════════════════════════${NC}"
                
                read -p "Enter site name for ${versions_to_install[$i]}: " site_name
                read -p "Install ERPNext for ${versions_to_install[$i]}? (yes/no): " install_erpnext
                install_erpnext=$(echo "$install_erpnext" | tr '[:upper:]' '[:lower:]')
                read -p "Setup production for ${versions_to_install[$i]}? (yes/no): " setup_production
                setup_production=$(echo "$setup_production" | tr '[:upper:]' '[:lower:]')
                
                perform_installation "$INSTALL_USER" "$INSTALL_HOME" "${versions_to_install[$i]}" "${bench_names[$i]}" \
                    "$site_name" "$sqlpasswrd" "$adminpasswrd" "$install_erpnext" "$setup_production"
                
                echo -e "${GREEN}✓ Completed ${versions_to_install[$i]} installation${NC}"
            done
            
            echo ""
            echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}     All installations completed successfully!           ${NC}"
            echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
            
            echo -e "${YELLOW}Summary of installations for user '$INSTALL_USER':${NC}"
            for i in "${!versions_to_install[@]}"; do
                echo -e "  • ${bench_names[$i]} (${versions_to_install[$i]})"
            done
            echo ""
            echo -e "${LIGHT_BLUE}To start benches:${NC}"
            for i in "${!versions_to_install[@]}"; do
                echo -e "  cd /home/$INSTALL_USER/${bench_names[$i]} && bench start"
            done
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

# Run main function
main_installation