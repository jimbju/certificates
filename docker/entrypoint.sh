#!/bin/bash
set -eo pipefail

# Paraphrased from:
# https://github.com/influxdata/influxdata-docker/blob/0d341f18067c4652dfa8df7dcb24d69bf707363d/influxdb/2.0/entrypoint.sh
# (a repo with no LICENSE.md)

export STEPPATH="/home/step"

# List of env vars required for step ca init
declare -ra REQUIRED_INIT_VARS=(DOCKER_STEPCA_INIT_NAME DOCKER_STEPCA_INIT_DNS_NAMES)

# Ensure all env vars required to run step ca init are set.
function init_if_possible () {
    local missing_vars=0
    for var in "${REQUIRED_INIT_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars=1
        fi
    done
    if [ ${missing_vars} = 1 ]; then
		>&2 echo "there is no ca.json config file; please run step ca init, or provide config parameters via DOCKER_STEPCA_INIT_ vars"
    else
        step_ca_init "${@}"
    fi
}

function generate_password () {
    set +o pipefail
    < /dev/urandom tr -dc A-Za-z0-9 | head -c40
    echo
    set -o pipefail
}

# Initialize a CA if not already initialized
function step_ca_init () {
    local -a setup_args=(
        --name "${DOCKER_STEPCA_INIT_NAME}"
		--dns "${DOCKER_STEPCA_INIT_DNS_NAMES}"
		--provisioner "${DOCKER_STEPCA_INIT_PROVISIONER_NAME:-admin}"
		--password-file "${STEPPATH}/password"
        --address ":9000"
    )
    if [ -n "${DOCKER_STEPCA_INIT_PASSWORD}" ]; then
        echo "${DOCKER_STEPCA_INIT_PASSWORD}" > "${STEPPATH}/password"
    else
        generate_password > "${STEPPATH}/password"
    fi
    if [ -n "${DOCKER_STEPCA_INIT_SSH}" ]; then
        setup_args=("${setup_args[@]}" --ssh)
    fi
    step ca init "${setup_args[@]}"
    mv $STEPPATH/password $PWDPATH
}

if [ ! -f "${STEPPATH}/config/ca.json" ]; then
	init_if_possible
    # Add insecure listener
    sed -i "s|insecureAddress\": \"\"|insecureAddress\": \":8080\"|" "${STEPPATH}/config/ca.json"
    # Remove certs and secrets that were created by step init
    rm -f /home/step/certs/*
    rm -f /home/step/secrets/*
    # Create a new root CA cert and key (RSA 2048)
    step certificate create root-ca /home/step/certs/root_ca.crt /home/step/secrets/root_ca.key --kty RSA --size 2048 --profile root-ca --no-password --insecure
    # Create a new intermediate CA cert and key (and sign with the root CA key)
    step certificate create root-ca /home/step/certs/intermediate_ca.crt /home/step/secrets/intermediate_ca_key --kty RSA --size 2048 --profile intermediate-ca --ca /home/step/certs/root_ca.crt --ca-key /home/step/secrets/root_ca.key --no-password --insecure
    # Add SCEP provisioner
    step ca provisioner add scep --type SCEP --challenge "secret"
fi

exec "${@}"
