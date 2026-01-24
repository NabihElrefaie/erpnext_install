# ERPNext Multi-Version Installation Manager

A comprehensive bash script for installing multiple ERPNext versions on a single server. Supports installations for different users and multiple ERPNext versions (v13, v14, v15, v16, develop) within the same user account.

## 📋 Table of Contents

- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Installation Modes](#-installation-modes)
- [Detailed Installation Guide](#-detailed-installation-guide)
- [Managing Installations](#-managing-installations)
- [Troubleshooting](#-troubleshooting)
- [Advanced Usage](#-advanced-usage)
- [Uninstallation](#-uninstallation)
- [FAQ](#-faq)

## ✨ Features

- 🚀 **Multiple Version Support**: Install ERPNext v13, v14, v15, v16, and develop branch
- 👥 **Multi-User Support**: Install for different Linux users or same user
- 🔥 **Conflict-Free**: Automatic port assignment prevents conflicts
- 🛡️ **Production Ready**: Complete SSL, supervisor, and production setup
- 📦 **Additional Apps**: Install extra Frappe apps from awesome-frappe
- ⚡ **Fast Installation**: Pre-collect all information upfront
- 🔧 **Automatic Configuration**: No manual prompts during installation

## 🚀 Prerequisites

### Operating System Support
- **Ubuntu**: 20.04, 22.04, 23.04, 24.04
- **Debian**: 9, 10, 11, 12

### Hardware Requirements
- **Minimum**: 4GB RAM, 2 CPU cores, 40GB storage
- **Recommended**: 8GB RAM, 4 CPU cores, 80GB storage
- **For Production**: 16GB RAM, 8 CPU cores, 200GB SSD

### Network Requirements
- **Open Ports**: 80, 443, 22 (or custom ports for multiple installations)
- **Domain Name**: Required for SSL setup (optional)
- **Static IP Recommended**: For stable production environments

## 🚀 Quick Start

### 🌐 Download and Install

```bash
# Clone the repository
git clone https://github.com/NabihElrefaie/erpnext_install.git
cd erpnext_install

# Make executable
chmod +x multi.sh

# Run the installer
sudo ./multi.sh
```

### 🔧 Installation Modes

#### Mode 1: Single Installation (Default)
Install a single ERPNext version for a specific user.

#### Mode 2: Multiple Versions (Same User)
Install multiple ERPNext versions under the same Linux user.

#### Mode 3: Different Users
Install ERPNext for different Linux users on the same server.

## 📖 Detailed Installation Guide

### Step 1: System Preparation
```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install curl wget git -y
```

### Step 2: Run Installer
```bash
# Execute the installation script
sudo ./multi.sh

# Follow the interactive prompts
# Choose installation mode
# Select ERPNext version
# Configure user and passwords
```

### Step 3: Configure Installation
The script will automatically:
- ✅ Collect all required information upfront
- ✅ Install Node.js, Python, and dependencies
- ✅ Set up MariaDB with proper configuration
- ✅ Create bench with correct version
- ✅ Configure production settings
- ✅ Set up SSL (if email provided)
- ✅ Configure supervisor and services

### Step 4: Access Your Installation
- **Development**: `http://your-server-ip:port`
- **Production**: `https://your-domain-name`

## 🛠️ Managing Installations

### Start/Stop Benches
```bash
# Start a specific bench
cd ~/frappe-bench-v15
bench start

# Stop a specific bench
cd ~/frappe-bench-v15
bench stop

# Check status
cd ~/frappe-bench-v15
bench status
```

### Multiple Benches Management
```bash
# List all benches for current user
ls -la ~ | grep bench

# Start multiple benches
cd ~/frappe-bench-v15 && bench start &
cd ~/frappe-bench-v16 && bench start &

# Monitor all benches
sudo supervisorctl status
```

### Port Configuration
Each installation automatically gets unique ports:
- **Base Port**: 18000 + installation_number
- **MariaDB**: 13306 + installation_number
- **Redis Queue**: 15000 + installation_number  
- **Redis Cache**: 16000 + installation_number
- **Redis SocketIO**: 17000 + installation_number
- **Bench**: 18000 + installation_number

### Port Assignment Examples
```
Installation 1 (v15):
- MariaDB: 13306
- Redis Queue: 15000
- Redis Cache: 16000
- Redis SocketIO: 17000
- Bench: 18000

Installation 2 (v16):
- MariaDB: 13307
- Redis Queue: 15001
- Redis Cache: 16001
- Redis SocketIO: 17001
- Bench: 18001
```

## 🔧 Troubleshooting

### Common Issues and Solutions

#### 1. Port Conflicts
**Symptoms**: "Port already in use" errors

**Solutions**:
```bash
# Check which ports are in use
sudo netstat -tulpn | grep LISTEN

# Kill conflicting processes
sudo kill -9 <PID>

# Use different ports by setting environment variables
export BENCH_PORT=18001
export MYSQL_PORT=13306
```

#### 2. MariaDB Connection Issues
**Symptoms**: Database connection failed

**Solutions**:
```bash
# Check MariaDB status
sudo systemctl status mariadb

# Restart MariaDB
sudo systemctl restart mariadb

# Check MariaDB logs
sudo tail -f /var/log/mysql/error.log

# Reset MariaDB root password
sudo mysql -u root -p
```

#### 3. Python Version Issues
**Symptoms**: Python version compatibility errors

**Solutions**:
```bash
# Check Python versions
python3 --version
python3.10 --version

# Install required Python version
sudo apt install python3.10 python3.10-venv
```

#### 4. Redis Issues
**Symptoms**: Redis services not starting

**Solutions**:
```bash
# Check Redis instances
ps aux | grep redis

# Restart Redis
sudo systemctl restart redis-server

# Clear Redis cache
redis-cli FLUSHALL
```

## ⚡ Advanced Usage

### Custom Port Configuration
To manually set ports for an installation:

```bash
# Set environment variables before installation
export MYSQL_PORT=13307
export REDIS_QUEUE_PORT=15001
export REDIS_CACHE_PORT=16001
export REDIS_SOCKETIO_PORT=17001
export BENCH_PORT=18001

# Run installer with custom ports
sudo ./multi.sh
```

### Custom Bench Configuration
```bash
# Edit bench configuration
cd ~/frappe-bench-v15
nano sites/common_site_config.json

# Example configuration:
{
    "db_host": "localhost",
    "db_port": 13307,
    "redis_cache": "redis://localhost:16001",
    "redis_queue": "redis://localhost:15001",
    "socketio_port": 17001
}
```

### Backup and Restore
```bash
# Backup a site
cd ~/frappe-bench-v15
bench --site your-site.com backup

# Restore a site
cd ~/frappe-bench-v15
bench --site your-site.com restore path/to/backup.sql.gz
```

### Performance Optimization
```bash
# Optimize MariaDB
sudo nano /etc/mysql/my.cnf

# Add these settings:
[mysqld]
innodb_buffer_pool_size = 256M
query_cache_size = 32M
```

### Multiple Instance Management
```bash
# Run multiple benches simultaneously
cd ~/frappe-bench-v15 && bench start &
cd ~/frappe-bench-v16 && bench start &

# Monitor all instances
watch -n 1 'sudo supervisorctl status'
```

## 🗑️ Uninstallation

### Remove Single Bench
```bash
# Stop bench services
cd ~/frappe-bench-v15
bench stop

# Remove supervisor configuration
sudo rm /etc/supervisor/conf.d/frappe-bench-v15.conf

# Remove bench directory
sudo rm -rf ~/frappe-bench-v15
```

### Remove Database
```bash
# Drop specific database
sudo mysql -u root -p
DROP DATABASE IF EXISTS your_database_name;

# Remove user and permissions
sudo mysql -u root -p
DROP USER IF EXISTS 'your-user'@'localhost';
```

### Complete Cleanup
```bash
# Remove all benches
sudo rm -rf ~/*-bench*

# Remove ERPNext users
sudo deluser erpnext-user1 erpnext-user2

# Remove services
sudo apt remove mariadb-server redis-server nginx supervisor -y
sudo apt autoremove -y
```

## ❓ FAQ

### Q1: Can I run multiple ERPNext versions simultaneously?
**A**: Yes! Each installation uses different ports and can run simultaneously.

### Q2: How much disk space do I need?
**A**: Each installation requires ~2-5GB. Plan for 10-15GB for multiple installations.

### Q3: Can I share databases between versions?
**A**: No, each version requires its own database due to schema differences.

### Q4: How do I access different installations?
**A**: 
- v15: `http://your-ip:18000`
- v16: `http://your-ip:18001`

### Q5: Can I install on cloud servers?
**A**: Yes! The script works on Ubuntu/Debian cloud instances.

### Q6: How do I update an existing installation?
**A**: Use `bench update` within the bench directory.

### Q7: What if installation fails?
**A**: Check logs in `~/bench-name/logs/` and use `bench doctor` for diagnostics.

## 🔧 System Files and Logs

### Log Locations
| Service | Log Location |
|----------|-------------|
| Bench | ~/bench-name/logs/ |
| Supervisor | /var/log/supervisor/ |
| Nginx | /var/log/nginx/ |
| MariaDB | /var/log/mysql/ |
| Redis | /var/log/redis/ |

### Configuration Files
| File | Location |
|------|---------|
| Bench Config | ~/bench-name/sites/common_site_config.json |
| Supervisor Config | /etc/supervisor/conf.d/ |
| Nginx Config | /etc/nginx/sites-available/ |
| MariaDB Config | /etc/mysql/my.cnf |

## 🚨 Security Considerations

### Database Security
- Use strong MariaDB root passwords
- Restrict database access to localhost
- Regular security updates

### Network Security
- Configure firewall for required ports only
- Use SSL certificates in production
- Regular security monitoring

### User Security
- Create dedicated ERPNext users
- Limit sudo access for service accounts
- Regular password rotation

## 🔄 Updates and Maintenance

### Update Script
```bash
# Get latest version
cd erpnext_install
git pull origin main

# Update to latest version
sudo cp multi.sh /usr/local/bin/erpnext-installer
```

### Regular Maintenance Tasks
```bash
# Weekly system updates
sudo apt update && sudo apt upgrade -y

# Backup all sites
cd ~ && for bench in */; do cd "$bench" && bench backup-all-sites; done

# Clean old logs
sudo find /var/log -name "*.log" -mtime +30 -delete
```

## 📈 Monitoring and Metrics

### Resource Monitoring
```bash
# System resources
htop                    # CPU and memory
iotop                   # Disk I/O
nethog                   # Network usage

# ERPNext specific
bench doctor              # Bench health check
bench --site status        # Site status
sudo supervisorctl status    # Service status
```

### Performance Metrics
```bash
# Database performance
mysql -e "SHOW STATUS LIKE 'Questions';"

# Redis performance
redis-cli info
redis-cli --latency-history

# Application performance
curl -s http://localhost:port/api/method/status
```

## 🎯 Best Practices

### Installation Planning
1. **Plan your architecture**: Single vs multiple installations
2. **Resource allocation**: Dedicated resources per installation
3. **Network planning**: Port allocation and firewall rules
4. **Backup strategy**: Regular backup schedule

### Security Best Practices
1. **Use strong passwords**: For database and admin accounts
2. **Regular updates**: System and application updates
3. **Access control**: Limited user permissions
4. **SSL certificates**: For all production environments

### Performance Best Practices
1. **Resource monitoring**: Regular performance checks
2. **Database optimization**: Proper MariaDB tuning
3. **Caching strategies**: Redis configuration optimization
4. **Load balancing**: Multiple instances for high availability

## 🙏 Acknowledgments

- **Frappe Technologies**: For the excellent ERPNext framework
- **Ubuntu/Debian**: For reliable operating systems
- **Open Source Community**: For valuable contributions and support
- **MariaDB/Redis/Nginx**: For robust backend technologies

---

## 📞 Getting Help and Support

### Documentation
- **ERPNext Documentation**: [https://docs.erpnext.com](https://docs.erpnext.com)
- **Frappe Framework**: [https://frappeframework.com](https://frappeframework.com)
- **Community Forum**: [https://discuss.erpnext.com](https://discuss.erpnext.com)

### Community Resources
- **Awesome Frappe**: [https://github.com/gavindsouza/awesome-frappe](https://github.com/gavindsouza/awesome-frappe)
- **Frappe Apps**: [https://frappecloud.com/marketplace](https://frappecloud.com/marketplace)

### Issue Reporting
- **GitHub Issues**: [https://github.com/NabihElrefaie/erpnext_install/issues](https://github.com/NabihElrefaie/erpnext_install/issues)
- **Bug Reports**: Include system info, logs, and error messages

---

## 📝 License

This script is provided under the MIT License. Use at your own risk.

---

**Last Updated**: 2026-01-24
**Version**: 1.0.0