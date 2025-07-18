#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}--------$1--------${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        print_error "Cannot detect operating system"
        exit 1
    fi
    
    if [[ "$OS" != *"Ubuntu"* ]] && [[ "$OS" != *"Debian"* ]]; then
        print_error "This script only supports Ubuntu and Debian"
        exit 1
    fi
}

install_mysql() {
    print_status "Installing MySQL"
    
    apt update
    apt install -y mysql-server
    
    print_success "MySQL installed successfully"
    
    print_warning "Securing MySQL installation..."
    
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -e "FLUSH PRIVILEGES;"
    
    print_success "MySQL secured successfully"
}

create_database_host() {
    print_status "Creating Database Host..."
    
    echo -n "Type your Password that you want the Database Host to have: "
    read -s DB_PASSWORD < /dev/tty
    echo ""
    
    if [[ -z "$DB_PASSWORD" ]]; then
        print_error "Database password cannot be empty"
        exit 1
    fi
    
    mysql -e "CREATE USER 'pelicanuser'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'127.0.0.1' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"
    
    print_success "Database user 'pelicanuser' created successfully"
}

allow_external_access() {
    print_status "Allowing external database access..."
    
    MYCNF_FILE=$(find /etc -name "my.cnf" 2>/dev/null | head -1)
    
    if [[ -z "$MYCNF_FILE" ]]; then
        MYCNF_FILE="/etc/mysql/my.cnf"
    fi
    
    if [[ ! -f "$MYCNF_FILE" ]]; then
        MYCNF_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"
    fi
    
    if [[ -f "$MYCNF_FILE" ]]; then
        if grep -q "bind-address" "$MYCNF_FILE"; then
            sed -i 's/bind-address.*/bind-address = 0.0.0.0/' "$MYCNF_FILE"
            print_success "Updated existing bind-address setting"
        else
            if grep -q "\[mysqld\]" "$MYCNF_FILE"; then
                sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' "$MYCNF_FILE"
                print_success "Added bind-address to [mysqld] section"
            else
                echo -e "\n[mysqld]\nbind-address = 0.0.0.0" >> "$MYCNF_FILE"
                print_success "Added [mysqld] section with bind-address"
            fi
        fi
    else
        echo -e "[mysqld]\nbind-address = 0.0.0.0" > /etc/mysql/conf.d/pelican.cnf
        print_success "Created new configuration file"
    fi
    
    systemctl restart mysql
    print_success "MySQL restarted successfully"
}

setup_firewall() {
    print_status "Setting Up Firewall Rules..."
    
    if command -v ufw &> /dev/null; then
        ufw allow 3306
        print_success "UFW rule added for MySQL port 3306"
    else
        print_warning "UFW not installed, skipping firewall configuration"
    fi
}

display_completion() {
    print_status "Successfully Created Database Host!"
    echo ""
    print_success "Pelican Database Host installation completed successfully!"
    echo ""
    print_warning "Database Details:"
    echo "Username: pelicanuser"
    echo "Host: 127.0.0.1"
    echo "Port: 3306"
    echo ""
    print_warning "Go to your Admin Panel in Pelican and click on Create Database Host"
    print_warning "and enter your Password you set and follow the Instructions by Pelican."
}

main() {
    echo -e "${BLUE}--------PELICAN DATABASE HOST INSTALLATION SCRIPT--------${NC}"
    echo -e "${GREEN}Made by: Verdanox${NC}"
    echo ""
    
    check_root
    detect_os
    
    print_warning "Installing Pelican Database Host on your server..."
    print_warning "Operating System: $OS $VERSION"
    echo ""
    
    install_mysql
    create_database_host
    allow_external_access
    setup_firewall
    display_completion
}

main "$@"
