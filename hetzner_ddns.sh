#!/bin/sh

self='hetzner_ddns'
version='0.2.6'
daemon=0

for arg in $(seq "$#"); do
    param="$(eval "echo \$$arg")"
    case "$param" in
        '--daemon'|'-d')
            daemon=1;;
        '--version'|'-v')
            printf '%s %s\n' "$self" "$version"
            exit 0;;
        '--help'|'-h')
		echo "${self} ${version} - Hetzner Dynamic DNS Daemon

Usage:

    Run on startup
        service hetzner_ddns enable

    Start
        service hetzner_ddns start

    Stop
        service hetzner_ddns stop

    Runtime messages log file
        Runtime log is located at /var/log/hetzner_ddns.log

    Multiple daemon instances (systemd only)
        systemctl <action> hetzner_ddns@CONFIG


Options:

    -d, --daemon    Detach from current shell and run as a deamon
    -h, --help      Print help and exit
    -v, --version   Print version and exit


Configuration: /usr/local/etc/hetzner_ddns.conf

    interval <seconds>      Seconds between updates
    key <32 character key>  Hetzner DNS API key
    domain <domain name>    Top level domain name
    records <hostname>...   Space separated host subdomains
    ipv4 <true|false>       Enable updating A records
    ipv6 <true|false>       Enable updating AAAA records
"
            exit 0;;
        *)
            self="${self}.$param";;
    esac
done

# Check dependencies
if ! command -v curl > /dev/null || \
   ! command -v awk > /dev/null || \
   ! command -v jq > /dev/null
then
    >&2 echo 'Error: missing dependency'
    exit 1
fi

# Check logging support
if ! touch "/var/log/$self.log";
then
    >&2 echo "Error: unable to open log file /var/log/$self.log"
    exit 2
fi

read_configuration() {
    # Read variabels from configuration file
    if test -r "/usr/local/etc/$self.conf"; then
        printf '[%s] Reading configuration from %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "/usr/local/etc/$self.conf" \
            | tee -a "/var/log/$self.log"
        # shellcheck disable=SC1090
        . "/usr/local/etc/$self.conf"
        records_escaped="$(echo "$records" | sed 's:\*:\\\*:g')"
    else
        printf '[%s] Error: unable to read configuration file %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "/usr/local/etc/$self.conf" | tee -a "/var/log/$self.log"
        >&2 echo "Error: unable to read configuration file /usr/local/etc/$self.conf"
        exit 78
    fi

    # Check configuration
    if [ -z "$interval" ]; then
        printf '[%s] Warning: interval is not set, defaulting to 60 seconds\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        interval=60
    fi
    if ! echo "$interval" | grep -qE '^[0-9]+$'; then
        printf '[%s] Error: interval value is invalid, exiting\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 74
    fi
    if [ -z "$key" ]; then
        printf '[%s] Error: API key is not set, unable to proceed\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 78
    fi
    if [ -z "$domain" ]; then
        printf '[%s] Error: domain is not set, unable to proceed\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 78
    fi
    if [ -z "$records" ]; then
        printf '[%s] Warning: records are not set, exiting cleanly\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 0
    fi
    if [ -z "$ipv4" ]; then
        printf '[%s] Info: update of A records not set, enabling by default\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        ipv4=true
    fi
    if ! echo "$ipv4" | grep -qE '^true|false$'; then
        printf '[%s] Error: update of A records flag is invalid, exiting\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 74
    fi
    if [ -z "$ipv6" ]; then
        printf '[%s] Info: update of AAAA records not set, enabling by default\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        ipv6=true
    fi
    if ! echo "$ipv4" | grep -qE '^true|false$'; then
        printf '[%s] Error: update of AAAA records flag is invalid, exiting\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 74
    fi

    # Test if updating is disabled
    if [ "$ipv4" = 'false' ] && [ "$ipv6" = 'false' ]; then
        printf '[%s] Updating of both A and AAAA records is disabled, exiting cleanly\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 0
    fi
}

test_api_key() {
    # Test API key validity
    if curl "https://dns.hetzner.com/api/v1/zones" \
        -H "Auth-API-Token: $key" 2>/dev/null | \
        grep -q 'Invalid authentication credentials'; then
        printf '[%s] Error: Invalid API key\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        exit 22
    fi
}

get_zone() {
    # Get zone ID
    zone="$(
        curl "https://dns.hetzner.com/api/v1/zones" \
            -H "Auth-API-Token: $key" 2>/dev/null | \
        jq -r '.zones[] | .name + " " + .id' | \
        awk -v d="$domain" '$1==d {print $2}'
    )"
    if [ -z "$zone" ]; then
        printf '[%s] Error: Unable to fetch zone ID for domain %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$domain" | tee -a "/var/log/$self.log"
        return 1
    else
        printf '[%s] Zone for %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$domain" "$zone" | tee -a "/var/log/$self.log"
        return 0
    fi
}

get_record() {
    # Get record IDs
    if [ -n "$zone" ]; then
        record_ipv4="$(
            echo "$records_json" | \
            jq -r '.records[] | .name + " " + .type + " " + .id' | \
            awk -v r="$1" -v d="$domain" \
                '($1==r || $1==sprintf("%s.%s",r,d)) && $2=="A" {print $3 }'
        )"
        record_ipv6="$(
            echo "$records_json" | \
            jq -r '.records[] | .name + " " + .type + " " + .id' | \
            awk -v r="$1" -v d="$domain" \
                '($1==r || $1==sprintf("%s.%s",r,d)) && $2=="AAAA" {print $3 }'
        )"
    fi
    if [ -z "$record_ipv4" ] && [ -z "$record_ipv6" ]; then
        return 1
    else
        printf '[%s] IPv4 record for %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1.$domain" \
            "${record_ipv4:-(missing)}" | tee -a "/var/log/$self.log"
        printf '[%s] IPv6 record for %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1.$domain" \
            "${record_ipv6:-(missing)}" | tee -a "/var/log/$self.log"
        return 0
    fi
}

get_records() {
    # Get all record IDs
    records_json="$(
        curl "https://dns.hetzner.com/api/v1/records?zone_id=$zone" \
            -H "Auth-API-Token: $key" 2>/dev/null
    )"
    for current_record in $records_escaped; do
        current_record="$(echo "$current_record" | sed 's:\\::')"
        if get_record "$current_record"; then
            records_ipv4="$records_ipv4$current_record=$record_ipv4 "
            records_ipv6="$records_ipv6$current_record=$record_ipv6 "
        else
            printf '[%s] Warning: Missing both A and AAAA records for %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$current_record.$domain" | tee -a "/var/log/$self.log"
        fi
    done
    if [ -z "$records_ipv4" ] && [ -z "$records_ipv6" ]; then
        printf '[%s] Error: No applicable records found %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$domain" | tee -a "/var/log/$self.log"
        return 1
    fi
}

get_record_ip_addr() {
    # Get record's IP address
    if [ -n "$record_ipv4" ]; then
        ipv4_rec="$(
            curl "https://dns.hetzner.com/api/v1/records/$record_ipv4" \
                -H "Auth-API-Token: $key" 2>/dev/null | \
            jq -r '.record.value'
        )"
    fi
    if [ -n "$record_ipv6" ]; then
        ipv6_rec="$(
            curl "https://dns.hetzner.com/api/v1/records/$record_ipv6" \
                -H "Auth-API-Token: $key" 2>/dev/null | \
            jq -r '.record.value'
        )"
    fi
    if [ -n "$record_ipv4" ]; then
        if [ -z "$ipv4_rec" ] || [ "$ipv4_rec" = 'null' ]; then
            printf '[%s] Warning: Unable to fetch previous IPv4 address for %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$current_record.$domain" | tee -a "/var/log/$self.log"
            ipv4_rec=''
        fi;
    fi
     if [ -n "$record_ipv6" ]; then
        if [ -z "$ipv6_rec" ] || [ "$ipv6_rec" = 'null' ]; then
            printf '[%s] Warning: Unable to fetch previous IPv6 address for %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$current_record.$domain" | tee -a "/var/log/$self.log"
            ipv6_rec=''
        fi;
    fi
    if [ -z "$ipv4_rec" ] && [ -z "$ipv6_rec" ]; then
        return 1
    fi
}

get_my_ip_addr() {
    # Get current public IP address
    if [ "$ipv4" = 'true' ]; then
        ipv4_cur="$(
            curl -4 'https://ip.hetzner.com/' 2>/dev/null
        )"
    fi
    if [ "$ipv6" = 'true' ]; then
        ipv6_cur="$(
            curl -6 'https://ip.hetzner.com/' 2>/dev/null | sed 's/:$/:1/g'
        )"
    fi
    if [ -z "$ipv4_cur" ] && [ -z "$ipv6_cur" ]; then
        printf '[%s] Error: Unable to fetch current self IP address\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
        return 1
    fi
}

set_record() {
    # Update record if IP address has changed
    if [ "$ipv4" = 'true' ] && [ -n "$record_ipv4" ] && [ -n "$ipv4_cur" ] && [ "$ipv4_cur" != "$ipv4_rec" ]; then
        curl -X "PUT" "https://dns.hetzner.com/api/v1/records/$record_ipv4" \
            -H 'Content-Type: application/json' \
            -H "Auth-API-Token: $key" \
            -d "{
            \"value\": \"$ipv4_cur\",
            \"ttl\": $interval,
            \"type\": \"A\",
            \"name\": \"$current_record\",
            \"zone_id\": \"$zone\"
            }" 1>/dev/null 2>/dev/null &&
        printf "[%s] Update IPv4 for %s: %s => %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$current_record.$domain" "$ipv4_rec" "$ipv4_cur" | tee -a "/var/log/$self.log"
    fi
    if [ "$ipv6" = 'true' ] && [ -n "$record_ipv6" ] && [ -n "$ipv6_cur" ] && [ "$ipv6_cur" != "$ipv6_rec" ]; then
        curl -X "PUT" "https://dns.hetzner.com/api/v1/records/$record_ipv6" \
            -H 'Content-Type: application/json' \
            -H "Auth-API-Token: $key" \
            -d "{
            \"value\": \"$ipv6_cur\",
            \"ttl\": $interval,
            \"type\": \"AAAA\",
            \"name\": \"$current_record\",
            \"zone_id\": \"$zone\"
            }" 1>/dev/null 2>/dev/null &&
        printf "[%s] Update IPv6 for %s: %s => %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$current_record.$domain" "$ipv6_rec" "$ipv6_cur" | tee -a "/var/log/$self.log"
    fi
}

pick_record() {
    # Get record ID from array
    echo "$2" | \
    awk "{
        for(i=1;i<=NF;i++){
            n=\$i;gsub(/=.*/,\"\",n);
            r=\$i;gsub(/.*=/,\"\",r);
            if(n==\"$1\"){
                print r;break
            }
        }}"
}

set_records() {
    # alternatively work with a variable
    old_ip_addr_file="/var/log/${self}_old_ip.txt"

    # Get my public IP address
    if get_my_ip_addr; then
		if [ "$(wc -l < "$old_ip_addr_file")" -eq 0 ]; then
		  echo "$ipv4_cur" > "$old_ip_addr_file"
		fi

		if [ "$ipv4_cur" != "$(cat "$old_ip_addr_file")" ]; then
          # Update all records if possible
          for current_record in $records_escaped; do
              current_record="$(echo "$current_record" | sed 's:\\::')"
              record_ipv4="$(pick_record "$current_record" "$records_ipv4")"
              record_ipv6="$(pick_record "$current_record" "$records_ipv6")"
              if [ -n "$record_ipv4" ] || [ -n "$record_ipv6" ]; then
                  get_record_ip_addr && set_record
              fi
          done
          echo "$ipv4_cur" > "$old_ip_addr_file"
# optionally log this?:
#        else
#		  printf '[%s] Nothing to do - ip has not changed\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
#		  | tee -a "/var/log/$self.log" 
        fi
    fi
}

run_ddns() {
    printf '[%s] Started Hetzner DDNS daemon\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
                | tee -a "/var/log/$self.log"

    read_configuration
    test_api_key

    while ! get_zone || ! get_records; do
        sleep $((interval/2+1))
        printf '[%s] Retrying to fetch zone and record data\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
                | tee -a "/var/log/$self.log"
    done

    printf '[%s] Configuration successful\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"
    printf '[%s] Watching for IP address and record changes\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "/var/log/$self.log"

    while true; do
        set_records
        sleep "$interval"
    done
}

if [ "$daemon" = '1' ]; then
    # Deamonize and write PID to file
    if touch "/var/run/$self.pid";
    then
        run_ddns &
        echo $! > "/var/run/$self.pid"
    else
        >&2 echo 'unable to daemonize'
        exit 2
    fi
else
    # Run in foreground
    run_ddns
fi
