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



trap 'handle_error $LINENO' ERR
set -e

# Error handling disabled for compatibility



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

# Run main function
main_installation
