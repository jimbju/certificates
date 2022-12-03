#!/bin/bash

set -eo pipefail

# Paraphrased from:
# https://github.com/influxdata/influxdata-docker/blob/0d341f18067c4652dfa8df7dcb24d69bf707363d/influxdb/2.0/entrypoint.sh
# (a repo with no LICENSE.md)

#export STEPPATH=$(step path)

# List of env vars required for step ca init
if [ ! -n "${ROOT_CA_CERTIFICATE}" ]; then
    declare -ra REQUIRED_INIT_VARS=(ROOT_CA_NAME DOCKER_STEPCA_INIT_NAME DOCKER_STEPCA_INIT_DNS_NAMES DOCKER_STEPCA_INIT_PROVISIONER_NAME DOCKER_STEPCA_ADDRESS)
else
    declare -ra REQUIRED_INIT_VARS=(DOCKER_STEPCA_INIT_NAME DOCKER_STEPCA_INIT_DNS_NAMES DOCKER_STEPCA_INIT_PROVISIONER_NAME DOCKER_STEPCA_ADDRESS)
fi

# Read environment variables (passed when starting the container)
#DOCKER_STEPCA_INIT_PROVISIONER_NAME
#DOCKER_STEPCA_INIT_NAME
#DOCKER_STEPCA_INIT_PASSWORD
#DOCKER_STEPCA_INIT_SSH
#DOCKER_STEPCA_ADDRESS
#DOCKER_STEPCA_INIT_DNS_NAMES
#ROOT_CA_NAME
#ROOT_CA_CERTIFICATE
#ROOT_CA_KEY_TYPE
#ROOT_CA_KEY_SIZE
#ROOT_CA_HASH_ALG
#ROOT_CA_CERT_VALIDITY
#ROOT_CA_MAX_PATH_LEN
#ICA_KEY_TYPE
#ICA_KEY_SIZE
#ICA_KEY_HASH_ALG
#ICA_CERT_VALIDITY
#PKI_COUNTRY_CODE
#PKI_ORGANIZATION
#PKI_ORGANIZATIONAL_UNIT
#PKCS11_LIBRARY
#FORTANIX_API_ENDPOINT
#FORTANIX_API_KEY

# Ensure all env vars required to run step ca init are set.
function init_if_possible () {
    local missing_vars=0
    for var in "${REQUIRED_INIT_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars=1
            echo "Required var missing ($var)"
        fi
    done
    if [ ${missing_vars} = 1 ]; then
		>&2 echo "Required config parameters were not specified via env vars"
        exit 1
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
        --deployment-type "standalone"
        --name "${DOCKER_STEPCA_INIT_NAME}"
		--dns "${DOCKER_STEPCA_INIT_DNS_NAMES}"
		--provisioner "${DOCKER_STEPCA_INIT_PROVISIONER_NAME:-admin}"
		--password-file "${STEPPATH}/password"
		--provisioner-password-file "${STEPPATH}/password"
        --address "${DOCKER_STEPCA_ADDRESS}"
    )
    if [ -n "${DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD}" ]; then
        echo "${DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD}" > "${STEPPATH}/password"
    else
        generate_password > "${STEPPATH}/password"
    fi
    if [ -n "${DOCKER_STEPCA_INIT_SSH}" ]; then
        setup_args=("${setup_args[@]}" --ssh)
    fi
    step ca init "${setup_args[@]}"
    mv $STEPPATH/password $PWDPATH
    # If a Fortanix DSM endpoint is set, the only thing we need to keep is the ca.json
    if [ -n "${FORTANIX_API_ENDPOINT}" ]; then
        rm -f $STEPPATH/certs/*
    fi
}

if [ ! -f "${STEPPATH}/config/ca.json" ]; then
	init_if_possible
    if [ -n "${FORTANIX_API_ENDPOINT}" ]; then
        # Set the pkcs#11 URI for accessing Fortanix DSM with the step kms plugin
        PKCS11_URI="pkcs11:module-path=${PKCS11_LIBRARY};slot-id=0;pin-value=${FORTANIX_API_KEY}"

        # Create some templates
        if [ ! -d "${STEPPATH}/templates" ]; then
            mkdir "${STEPPATH}/templates"
        fi
        organization_json="{
            \"country\": \"${PKI_COUNTRY_CODE}\",
            \"organization\": \"${PKI_ORGANIZATION}\",
            \"organizationalUnit\": \"${PKI_ORGANIZATIONAL_UNIT}\"
            }"
        
        intermediate_template="{
            \"subject\": {
                \"country\": \"${PKI_COUNTRY_CODE}\",
                \"organization\": \"${PKI_ORGANIZATION}\",
                \"organizationalUnit\": \"${PKI_ORGANIZATIONAL_UNIT}\",
                \"commonName\": \"${DOCKER_STEPCA_INIT_NAME}\"
            },
            \"keyUsage\": [\"certSign\", \"crlSign\"],
            \"basicConstraints\": {
                \"isCA\": true,
                \"maxPathLen\": ${ICA_MAX_PATH_LEN:=0}
            }
        }"
        if [ -n "${ROOT_CA_NAME}" ]; then
            root_template="{
                \"subject\": {
                    \"commonName\": \"${ROOT_CA_NAME}\"
                },
                \"issuer\": {
                    \"commonName\": \"${ROOT_CA_NAME}\"
                },
                \"keyUsage\": [\"certSign\", \"crlSign\"],
                \"basicConstraints\": {
                    \"isCA\": true,
                    \"maxPathLen\": ${ROOT_CA_MAX_PATH_LEN:=1}
                }
            }"
            echo $root_template > "${STEPPATH}/templates/root_template.tpl"
        fi
        echo $organization_json > "${STEPPATH}/templates/organization.json"
        echo $intermediate_template > "${STEPPATH}/templates/intermediate_template.tpl"

        # Generate the SSH keys in Fortanix DSM
        if [ -n "${DOCKER_STEPCA_INIT_SSH}" ]; then
            SSH_CA_HOST_KEY_PKCS11_CKA_ID=$(uuidgen | sed 's/-//g')
            SSH_CA_HOST_KEY_PKCS11_OBJECT_NAME=$(echo "${DOCKER_STEPCA_INIT_NAME}-ssh_host_key" | sed 's/ /_/g' | sed 's/\(.*\)/\L\1/g')
            SSH_CA_USER_KEY_PKCS11_CKA_ID=$(uuidgen | sed 's/-//g')
            SSH_CA_USER_KEY_PKCS11_OBJECT_NAME=$(echo "${DOCKER_STEPCA_INIT_NAME}-ssh_user_key" | sed 's/ /_/g' | sed 's/\(.*\)/\L\1/g')

            # Create SSH CA host key
            step_args=(
                --kms "${PKCS11_URI}"
                "pkcs11:id=${SSH_CA_HOST_KEY_PKCS11_CKA_ID};object=${SSH_CA_HOST_KEY_PKCS11_OBJECT_NAME}"
            )
            step kms create "${step_args[@]}"

            # Create SSH CA user key
            step_args=(
                --kms "${PKCS11_URI}"
                "pkcs11:id=${SSH_CA_USER_KEY_PKCS11_CKA_ID};object=${SSH_CA_USER_KEY_PKCS11_OBJECT_NAME}"
            )
            step kms create "${step_args[@]}"
        fi

        # Generate the ICA key in Fortanix DSM
        ICA_KEY_PKCS11_CKA_ID=$(uuidgen | sed 's/-//g')
        ICA_KEY_PKCS11_OBJECT_NAME=$(echo "${DOCKER_STEPCA_INIT_NAME}-key" | sed 's/ /_/g' | sed 's/\(.*\)/\L\1/g')

        step_args=(
            --kms "${PKCS11_URI}"
            "pkcs11:id=${ICA_KEY_PKCS11_CKA_ID};object=${ICA_KEY_PKCS11_OBJECT_NAME}"
        )

        if [ -n "${ICA_KEY_TYPE}" ]; then
            step_args=("${step_args[@]}" --kty "${ICA_KEY_TYPE}")
        fi

        if [ -n "${ICA_KEY_SIZE}" ]; then
            step_args=("${step_args[@]}" --size "${ICA_KEY_SIZE}")
        fi

        if [ -n "${ICA_KEY_CURVE}" ]; then
            step_args=("${step_args[@]}" --crv "${ICA_KEY_CURVE}")
        fi

        if [ -n "${ICA_KEY_HASH_ALG}" ]; then
            step_args=("${step_args[@]}" --alg "${ICA_KEY_HASH_ALG}")
        fi

        step kms create "${step_args[@]}"

        # Generate the root CA key in Fortanix DSM
        if [ -n "${ROOT_CA_NAME}" ]; then
            ROOT_CA_KEY_PKCS11_CKA_ID=$(uuidgen | sed 's/-//g')
            ROOT_CA_KEY_PKCS11_OBJECT_NAME=$(echo "${ROOT_CA_NAME}-key" | sed 's/ /_/g' | sed 's/\(.*\)/\L\1/g')
            # Generate key
            step_args=(
                --kms "${PKCS11_URI}"
                "pkcs11:id=${ROOT_CA_KEY_PKCS11_CKA_ID};object=${ROOT_CA_KEY_PKCS11_OBJECT_NAME}"
            )

            if [ -n "${ROOT_CA_KEY_TYPE}" ]; then
                step_args=("${step_args[@]}" --kty "${ROOT_CA_KEY_TYPE}")
            fi

            if [ -n "${ROOT_CA_KEY_SIZE}" ]; then
                step_args=("${step_args[@]}" --size "${ROOT_CA_KEY_SIZE}")
            fi

            if [ -n "${ROOT_CA_KEY_CURVE}" ]; then
                step_args=("${step_args[@]}" --crv "${ROOT_CA_KEY_CURVE}")
            fi
            
            if [ -n "${ROOT_CA_KEY_HASH_ALG}" ]; then
                step_args=("${step_args[@]}" --alg "${ROOT_CA_KEY_HASH_ALG}")
            fi

            step kms create "${step_args[@]}"

            # Create the root CA certificate
            step_args=(
                --template "${STEPPATH}/templates/root_template.tpl"
                --kms "${PKCS11_URI}"
                --key "pkcs11:id=${ROOT_CA_KEY_PKCS11_CKA_ID}"
                "${ROOT_CA_NAME}"
                "${STEPPATH}/certs/root_ca.crt"
            )

            if [ -n "${ROOT_CA_CERT_VALIDITY}" ]; then
                step_args=("${step_args[@]}" --not-after "${ROOT_CA_CERT_VALIDITY}")
            fi
            echo "step certificate create ${step_args[@]}"
            step certificate create "${step_args[@]}"

            # Create the ICA certificate (and sign it with the root key)
            step_args=(
                --template "${STEPPATH}/templates/intermediate_template.tpl"
                --kms "${PKCS11_URI}"
                --ca "${STEPPATH}/certs/root_ca.crt"
                --ca-key "pkcs11:id=${ROOT_CA_KEY_PKCS11_CKA_ID}"
                --key "pkcs11:id=${ICA_KEY_PKCS11_CKA_ID}"
                "${DOCKER_STEPCA_INIT_NAME}"
                "${STEPPATH}/certs/intermediate_ca.crt"
            )

            if [ -n "${ICA_CERT_VALIDITY}" ]; then
                step_args=("${step_args[@]}" --not-after "${ICA_CERT_VALIDITY}")
            fi

            step certificate create "${step_args[@]}"
        fi

        if [ -n "${ROOT_CA_CERTIFICATE}" ]; then
            # Write the root ca certificate to a file
            echo "${ROOT_CA_CERTIFICATE}" > "${STEPPATH}/certs/root_ca.crt"

            # Generate a CSR for the intermediate CA using the key in Fortanix DSM
            step_args=(
                --csr
                --template "${STEPPATH}/templates/intermediate_template.tpl"
                --kms "${PKCS11_URI}"
                --key "pkcs11:id=${ICA_KEY_PKCS11_CKA_ID}"
                "${DOCKER_STEPCA_INIT_NAME}"
                "${STEPPATH}/certs/intermediate_ca.csr"
            )

            step certificate create "${step_args[@]}"
            
            # Print the CSR on screen
            cat "${STEPPATH}/certs/intermediate_ca.csr"
            # Wait for the intermediate_ca.crt to be created before continuing
            while [ ! -f "${STEPPATH}/certs/intermediate_ca.crt" ]; 
                do sleep 10 && echo "waiting for ${STEPPATH}/certs/intermediate_ca.crt"; 
            done
        fi
        # Update config/ca.json with some pkcs#11 related stuff
        sed -i "0,/{/{s|{|{\n\t\"kms\": {\n\t\t\"type\": \"pkcs11\",\n\t\t\"uri\": \"pkcs11:module-path=$PKCS11_LIBRARY;slot-id=0;pin-value=$FORTANIX_API_KEY\"\n\t},|}" "${STEPPATH}/config/ca.json"
        sed -i "s|/home/step/secrets/intermediate_ca_key|pkcs11:id=${ICA_KEY_PKCS11_CKA_ID};object=${ICA_KEY_PKCS11_OBJECT_NAME}|" "${STEPPATH}/config/ca.json"
        if [ -n "${ROOT_CA_NAME}" ]; then
            sed -i "s|/home/step/secrets/root_ca_key|pkcs11:id=${ROOT_CA_KEY_PKCS11_CKA_ID};object=${ROOT_CA_KEY_PKCS11_OBJECT_NAME}|" "${STEPPATH}/config/ca.json"
        fi
        if [ -n "${DOCKER_STEPCA_INIT_SSH}" ]; then
            sed -i "s|/home/step/secrets/ssh_host_ca_key|pkcs11:id=${SSH_CA_HOST_KEY_PKCS11_CKA_ID};object=${SSH_CA_HOST_KEY_PKCS11_OBJECT_NAME}|" "${STEPPATH}/config/ca.json"
            sed -i "s|/home/step/secrets/ssh_user_ca_key|pkcs11:id=${SSH_CA_USER_KEY_PKCS11_CKA_ID};object=${SSH_CA_USER_KEY_PKCS11_OBJECT_NAME}|" "${STEPPATH}/config/ca.json"
        fi
    fi
fi

exec "${@}"
