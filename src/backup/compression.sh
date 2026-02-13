#!/usr/bin/env bash
#
# Compression


# bk_type_backup_compression: Compress files based in the algoritm
# Uses key: Compression=
bk_type_backup_compression() {
  local task="$1" workdir="$2" artifactdir="$3"
  local compress file_name out_file ext

  # default Compression=tar (cannot exist Backup without compression).
  compress="${cfg[Compression]-tar}"
  file_name="$(bk_build_artifact_name)"

  fn_debug "Packing workdir in: $compress"

  case "$compress" in
    tar)
      out_file="${artifactdir}/${file_name}.tar"
      ext=".tar"
      (cd "$workdir" && tar -cf "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    tar.gz|tgz)
      out_file="${artifactdir}/${file_name}.tar.gz"
      ext=".tar.gz"
      (cd "$workdir" && tar -czf "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    zip)
      out_file="${artifactdir}/${file_name}.zip"
      ext=".zip"
      (cd "$workdir" && zip -qr "$out_file" . ) || { fn_error "Failed to compress into $out_file"; return 1; }
      ;;
    *)
      fn_error "[$task] Unsupported Compress format: $compress"
      return 1
      ;;
  esac
  # sets artifact
  cfg[Artifact]="$out_file"
  cfg[ArtifactName]="${file_name}${ext}"
  cfg[ArtifactExt]="${ext}"

  fn_debug "Artifact generated: ${cfg[ArtifactName]}"

  # remove workdir
  #rm -rf -- "$workdir/*"
}
