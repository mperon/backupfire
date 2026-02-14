#!/usr/bin/env bash
#
# Decrypt function
BK_DECRYPT_KEY_PEM=

# explain the function here
# usage
bk_cmd_decrypt() {
  local path="$BK_DECRYPT" tmpd= encf= keyf=
  local file_name= out_file=

  # check if file exists and is readable
  if [[ -z "$path" ]] || [[ ! -f "$path" ]] || \
    [[ ! -r "$path" ]]; then
    fn_error "The file is not valid or is not readable"
    return 2
  fi

  # search for a valid private key file
  fn_debug "Searching for a valid private key: "
  if ! bk_encrypt_set_private_key "$1" "$tmpd"; then
    fn_error "You don't have a private key (id_rsa) in your system or " \
    "you passed an invalid private key (with -k)"
    return 2
  fi

  fn_debug "Private key found: $BK_DECRYPT_KEY_PEM"

  # create a temporary directory
  bk_mktemp_set 'tmpd' "decrypt" "d" "dir"

  fn_debug "Creating temporary directory: $tmpd"

  fn_debug "Opening encrypted archive: $path"
  fn_run tar -xf "$path" -C "$tmpd"

  #file extracted, now get the file with extension
  # find the enc file
  encf="$(find "$tmpd" -type f -name '*.enc' -print -quit)"
  if [[ -z "$encf" ]] || [[ ! -f "$encf" ]] || \
    [[ ! -r "$encf" ]]; then
    fn_debug "Was not possible to find the encrypted (.enc) file inside the archive"
    fn_error "The file passed for decryption is invalid or it's corrupted."
    return 2
  fi

  # find the secret file
  keyf="$(find "$tmpd" -type f -name '*.secret' -print -quit)"
  if [[ -z "$keyf" ]] || [[ ! -f "$keyf" ]] || \
    [[ ! -r "$keyf" ]]; then
    fn_debug "Was not possible to find the key (.secret) file inside the archive"
    fn_error "The file passed for decryption is invalid or it's corrupted."
    return 2
  fi

  fn_debug "      Key file detected: $keyf"
  fn_debug "Encrypted file detected: $encf"

  file_name="${encf##*/}"   # remove directory
  file_name="${file_name%.*}" # remove last extension
  out_file="$tmpd/${file_name}.archive"

  fn_debug "Decrypting key file ..."
  # decrypt the key
  fn_run $OPENSSL_CMD pkeyutl -decrypt -inkey "${BK_DECRYPT_KEY_PEM}" \
    -in "$keyf" -out "$tmpd/keyfile"

  if [[ $? -ne 0 ]] || [[ ! -r "$tmpd/keyfile" ]]; then
    fn_error "It was impossible to decrypt keyfile: $keyf"
    return 2
  fi

  fn_debug "Decrypting the file: $encf to $out_file ..."
  # decrypt the file:
  fn_run $OPENSSL_CMD enc -d -aes-256-cbc -salt -pbkdf2 -pass "file:$tmpd/keyfile" \
  -in "$encf" -out "$out_file"

  if [[ $? -ne 0 ]] || [[ ! -r "$out_file" ]]; then
    fn_error "It was impossible to decrypt archive: $encf"
    return 2
  fi

  fn_debug "Extracting encrypted archive to directory: ./$file_name"

  # extract the compressed file:
  if ! bk_decrypt_detect_archive "$out_file" "./${file_name}"; then
    fn_error "The key provided is invalid or the file it's corrupted."
    return 2
  fi

  # finished
  return 0
}

bk_encrypt_set_private_key() {
  local path="$1" tmpd="$2"
  local keyf="${BK_DECRYPT_KEY:-$HOME/.ssh/id_rsa}"
  local bk_head=

  bk_mktemp_set 'BK_DECRYPT_KEY_PEM' "decrypt" "key" "file"

  # check if file exists and is readable
  if [[ -z "$keyf" ]] || [[ ! -f "$keyf" ]] || \
    [[ ! -r "$keyf" ]]; then
    fn_error "The file $keyf is not valid or is not readable"
    return 2
  fi

  #copy the key and work in the copyed version
  fn_run cp "$keyf" "$BK_DECRYPT_KEY_PEM"

  # check if key is in PEM format
  IFS= read -r bk_head < "$BK_DECRYPT_KEY_PEM"
  if [[ "$bk_head" != "-----BEGIN RSA PRIVATE KEY-----" ]]; then
    #need conversion
    fn_run ssh-keygen -p -m PEM -f "$BK_DECRYPT_KEY_PEM"
  fi

  # last check
  IFS= read -r bk_head < "$BK_DECRYPT_KEY_PEM"
  [[ "$bk_head" == *"BEGIN RSA PRIVATE KEY"* ]] && return 0 || return 2
}


bk_decrypt_detect_archive() {
  local f="$1" tmpd="$2"

  #its a zip file
  if unzip -tqq -- "$f" >/dev/null 2>&1; then
    mkdir -p "$tmpd"
    fn_run unzip -qq -- "$f" -d "$tmpd" || return 1
    return 0
  fi

  # its a tar.gz
  if tar -tzf "$f" >/dev/null 2>&1; then
    mkdir -p "$tmpd"
    fn_run tar -xzf "$f" -C "$tmpd" || return 1
    return 0
  fi

  # its a tar file
  if tar -tf "$f" >/dev/null 2>&1; then
    mkdir -p "$tmpd"
    fn_run tar -xf "$f" -C "$tmpd" || return 1
    return 0
  fi

  # invalid file
  return 2
}
