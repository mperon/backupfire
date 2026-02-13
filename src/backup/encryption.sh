#!/usr/bin/env bash
#
# Encryption


bk_type_backup_encryption() {
  local task="$1" workdir="$2" artifactdir="$3"

  if ! fn_boolean "${cfg[Encrypt]:-True}"; then
    fn_debug "Encription was disabled by Encrypt= option. skipping..."
    return 0
  fi

  [[ -z "${cfg[EncryptKeyFile]}" ]] && [[ -z "${cfg[EncryptKey]}" ]] && { \
    fn_debug "Encription was disabled by not setting EncryptKey* opts. skipping..."
    return 0
  }

  if ! bk_backup_encryption_checks; then
    return 1
  fi

  # checks if directory exists
  [[ ! -d "${cfg[ArtifactDir]}" ]] \
    && { fn_error "Task artifact dir doesn't exist: ${cfg[ArtifactDir]}"; return 1; }

  [[ ! -f "${cfg[Artifact]}" ]] \
    && { fn_error "Task artifact file doesn't exist: ${cfg[Artifact]}"; return 1; }

  [[ ! -r "${cfg[PEMKeyFile]}" ]] \
    && { fn_error "The encription key was not generated: ${cfg[PEMKeyFile]}"; return 1; }

  fn_debug "Encryption enabled. Using Key at: ${cfg[PEMKeyFile]}"

  pushd "${cfg[ArtifactDir]}" >/dev/null || return 1

    local secret=
    bk_mktemp_set 'secret' "$task" "secret" -f
    local artifact="$(bk_build_artifact_name)"

    fn_debug "Encryption: Generating private key from public provided key.."
    #generate a private key to be used
    fn_run $OPENSSL_CMD rand -base64 256 > "$secret"
    fn_run $OPENSSL_CMD pkeyutl -encrypt -inkey "${cfg[PEMKeyFile]}" \
      -pubin -in "$secret" -out "${artifact}.secret"

    fn_debug "Encrypting data.."
    fn_run $OPENSSL_CMD enc -aes-256-cbc -salt -pbkdf2 -pass "file:$secret" \
      -in "${cfg[Artifact]}" -out "${artifact}.enc"

    #delete the key as soon possible
    rm -f -- "$secret"

    fn_debug "Packing encripted data in: ${artifact}.backup"

    # pack everything in a tar file (withouth compression)
    fn_run tar -cf "${artifact}.backup" "${artifact}.secret" \
      "${artifact}.enc"

    # sets the final production file
    cfg[Artifact]="$artifactdir/${artifact}.backup"
    cfg[ArtifactName]="${artifact}.backup"
    cfg[ArtifactExt]=".backup"

  popd >/dev/null || return 1

}

bk_backup_encryption_checks() {
  local tempk= firstline= encd=
  bk_mktemp_set 'encd' "$task" "encd"
  local keyf="$encd/keyfile"  sshk="$encd/ssh-temp"

  #check if encription key is set (file or text)
  if [[ -n "${cfg[EncryptKeyFile]}" ]]; then
    [[ ! -f "${cfg[EncryptKeyFile]}" ]] && fn_error "Key file doesn't exists!" && return 1
    # check if file is a PEM file
    IFS= read -r firstline < "${cfg[EncryptKeyFile]}"
    if [[ "$firstline" == *"-----BEGIN "* ]]; then
      # key is a valid pem key
      cat "${cfg[EncryptKeyFile]}" > "$keyf"
      cfg[PEMKeyFile]="$keyf"
      return 0
    else
      # need to be converted
      tempk=1
      cat "${cfg[EncryptKeyFile]}" > "$sshk"
    fi
  elif [[ -n "${cfg[EncryptKey]}" ]]; then
    if [[ "${cfg[EncryptKey]}" == ssh-* ]]; then
      # its a valid key. generate pem from it
      tempk=1
      printf '%s' "${cfg[EncryptKey]}" > "$sshk"
    else
      fn_error "Unsupported key format. Need to be: ssh-rsa XXX"
      return 1
    fi
  fi
  chmod 0644 "$sshk" 2>/dev/null || true
  # if its a temp key, convert:
  if [[ "$tempk" -gt 0 ]]; then
    if ssh-keygen -f "$sshk" -e -m PEM >"$keyf" 2>/dev/null; then
      IFS= read -r firstline < "$keyf"
      if [[ "$firstline" == *"-----BEGIN "* ]]; then
        cfg[PEMKeyFile]="$keyf"
        return 0
      fi
    fi
  fi
  fn_error "Invaid key! Set EncryptKeyFile or EncryptKey in Task settigs.."
  return 1
}
