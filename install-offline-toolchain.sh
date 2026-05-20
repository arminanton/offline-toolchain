#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install-offline-toolchain.sh
# No-root modular installer for offline toolchain bundles.
#
# Usage from mounted persistent storage:
#   PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh --list
#   PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh php
#   PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh jdk gradle
#   PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh all
#
# If no module is specified, the installer installs every module bundle it can
# find in the same directory as this script. Split .part-* bundles are
# reassembled and checksum-verified automatically.

PREFIX="${PREFIX:-$HOME/.offline-toolchain}"
FORCE="${FORCE:-no}"
DEFAULT_JDK_V="${DEFAULT_JDK_V:-25}"
BUNDLE_STORE="${BUNDLE_STORE:-}"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown-time)" "$*" >&2; }

usage() {
  cat >&2 <<'EOF_USAGE'
Usage:
  install-offline-toolchain.sh [--list] [all|jdk|gradle|rust|php|cxx|node|python|cli|iac|podman|images ...]

Environment:
  PREFIX=/path/to/install-root        default: $HOME/.offline-toolchain
  BUNDLE_STORE=/path/to/module/files  default: directory containing this script
  DEFAULT_JDK_V=25                    default Java version after JDK install
  FORCE=yes                           replace existing installed module files

Examples:
  PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh php
  PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh jdk gradle
  PREFIX="$HOME/.offline-toolchain" ./install-offline-toolchain.sh all
  source "$HOME/.offline-toolchain/env.sh"
EOF_USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command on target: $1"
    exit 1
  }
}

sha256_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    log "Missing sha256sum or shasum for checksum verification"
    exit 1
  fi
}

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) log "Unsupported architecture: $ARCH_RAW"; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_STORE="${BUNDLE_STORE:-$SCRIPT_DIR}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

need tar
need gzip
need awk
need sed
need find
need cp
need ln
need mkdir
need chmod
need cat
need uname

mkdir -p \
  "$PREFIX/bin" \
  "$PREFIX/jdks" \
  "$PREFIX/gradle" \
  "$PREFIX/gradle-home" \
  "$PREFIX/rust" \
  "$PREFIX/php" \
  "$PREFIX/cxx" \
  "$PREFIX/node" \
  "$PREFIX/python" \
  "$PREFIX/cli" \
  "$PREFIX/podman" \
  "$PREFIX/images" \
  "$PREFIX/templates" \
  "$PREFIX/metadata"

module_bundle_base() {
  local module="$1"
  printf 'offline-%s-%s.tar.gz' "$module" "$ARCH"
}

module_bundle_present() {
  local module="$1"
  local base
  base="$(module_bundle_base "$module")"
  [ -f "$BUNDLE_STORE/$base" ] && return 0
  compgen -G "$BUNDLE_STORE/$base.part-*" >/dev/null && return 0
  return 1
}

list_modules() {
  local module
  for module in jdk gradle rust php cxx node python cli iac podman images; do
    if module_bundle_present "$module"; then
      printf '%s\n' "$module"
    fi
  done
}

resolve_module_archive() {
  local module="$1"
  local base archive checksum expected actual parts_file
  base="$(module_bundle_base "$module")"
  archive="$BUNDLE_STORE/$base"
  checksum="$BUNDLE_STORE/$base.sha256"
  parts_file="$BUNDLE_STORE/$base.parts"

  if [ -f "$archive" ]; then
    RESOLVED_MODULE_ARCHIVE="$archive"
  elif compgen -G "$archive.part-*" >/dev/null; then
    RESOLVED_MODULE_ARCHIVE="$TMP_ROOT/$base"
    log "Reassembling split module bundle: $base"
    # Sort lexicographically; part suffixes are zero-padded.
    cat $(printf '%s\n' "$archive".part-* | sort) > "$RESOLVED_MODULE_ARCHIVE"
  else
    log "Module bundle not found for '$module' in $BUNDLE_STORE"
    log "Expected $base or $base.part-*"
    exit 1
  fi

  if [ -f "$checksum" ]; then
    expected="$(awk '{print $1}' "$checksum" | head -n1)"
    actual="$(sha256_value "$RESOLVED_MODULE_ARCHIVE")"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
      log "Checksum mismatch for $base"
      log "Expected: $expected"
      log "Actual:   $actual"
      exit 1
    fi
    log "Checksum verified for $base"
  fi

  if [ -f "$parts_file" ]; then
    log "Using split manifest: $(basename "$parts_file")"
  fi
}

extract_module_bundle() {
  local module="$1"
  local archive extract_dir topdir
  resolve_module_archive "$module"
  archive="$RESOLVED_MODULE_ARCHIVE"
  extract_dir="$TMP_ROOT/extract-$module"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"
  topdir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
  if [ -z "$topdir" ]; then
    log "Could not find top-level directory in $archive"
    exit 1
  fi
  EXTRACTED_MODULE_DIR="$topdir"
}

copy_tree_contents() {
  local src="$1"
  local dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -)
}

extract_single_topdir_tgz() {
  local archive="$1"
  local target_parent="$2"
  local final_name="$3"
  local tmpd topdir target

  tmpd="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmpd"
  topdir="$(find "$tmpd" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
  if [ -z "$topdir" ]; then
    log "Archive has no single top-level directory: $archive"
    rm -rf "$tmpd"
    exit 1
  fi

  target="$target_parent/$final_name"
  if [ -e "$target" ] && [ "$FORCE" != "yes" ]; then
    log "Keeping existing: $target"
    rm -rf "$tmpd"
    return
  fi

  rm -rf "$target"
  mkdir -p "$target_parent"
  mv "$topdir" "$target"
  rm -rf "$tmpd"
}

install_jdk_assets() {
  local assets_dir="$1"
  local archive base version target default_home highest_version=""
  shopt -s nullglob
  for archive in "$assets_dir"/jdks/openjdk-*-${ARCH}.tar.gz; do
    base="$(basename "$archive")"
    version="$(printf '%s\n' "$base" | sed -E 's/^openjdk-[^-]+-([0-9]+)-.*$/\1/')"
    [ -n "$version" ] || continue
    log "Installing JDK $version from $base"
    extract_single_topdir_tgz "$archive" "$PREFIX/jdks" "jdk-$version"
    target="$PREFIX/jdks/jdk-$version"
    [ -x "$target/bin/java" ] || { log "Installed JDK $version missing java"; exit 1; }
    [ -x "$target/bin/javac" ] || { log "Installed JDK $version missing javac"; exit 1; }
    [ -x "$target/bin/jar" ] || { log "Installed JDK $version missing jar"; exit 1; }
    ln -sfn "$target/bin/java" "$PREFIX/bin/java$version"
    ln -sfn "$target/bin/javac" "$PREFIX/bin/javac$version"
    ln -sfn "$target/bin/jar" "$PREFIX/bin/jar$version"
    [ -x "$target/bin/jcmd" ] && ln -sfn "$target/bin/jcmd" "$PREFIX/bin/jcmd$version"
    [ -x "$target/bin/jstack" ] && ln -sfn "$target/bin/jstack" "$PREFIX/bin/jstack$version"
    [ -x "$target/bin/jmap" ] && ln -sfn "$target/bin/jmap" "$PREFIX/bin/jmap$version"
    highest_version="$version"
  done
  shopt -u nullglob

  default_home="$PREFIX/jdks/jdk-$DEFAULT_JDK_V"
  if [ ! -x "$default_home/bin/java" ] && [ -n "$highest_version" ]; then
    default_home="$PREFIX/jdks/jdk-$highest_version"
    DEFAULT_JDK_V="$highest_version"
  fi

  if [ -x "$default_home/bin/java" ]; then
    ln -sfn "$default_home/bin/java" "$PREFIX/bin/java"
    ln -sfn "$default_home/bin/javac" "$PREFIX/bin/javac"
    ln -sfn "$default_home/bin/jar" "$PREFIX/bin/jar"
  fi
}

install_gradle_assets() {
  local assets_dir="$1"
  local archive gradle_dir cache tmpd
  shopt -s nullglob
  for archive in "$assets_dir"/gradle/gradle-*-*.tar.gz; do
    log "Installing Gradle from $(basename "$archive")"
    mkdir -p "$PREFIX/gradle"
    tar -xzf "$archive" -C "$PREFIX/gradle"
  done
  shopt -u nullglob

  gradle_dir="$(find "$PREFIX/gradle" -maxdepth 1 -mindepth 1 -type d -name 'gradle-*' | sort | tail -n1 || true)"
  if [ -n "$gradle_dir" ] && [ -x "$gradle_dir/bin/gradle" ]; then
    cat > "$PREFIX/bin/gradle" <<EOF_GRADLE_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"
exec "$gradle_dir/bin/gradle" "\$@"
EOF_GRADLE_WRAPPER
    chmod +x "$PREFIX/bin/gradle"

    cat > "$PREFIX/bin/gradle-offline" <<EOF_GRADLE_OFFLINE
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"
exec "$gradle_dir/bin/gradle" --offline "\$@"
EOF_GRADLE_OFFLINE
    chmod +x "$PREFIX/bin/gradle-offline"
  fi

  cache="$assets_dir/gradle/gradle-cache-${ARCH}.tar.gz"
  if [ -f "$cache" ]; then
    log "Installing warmed Gradle cache"
    tmpd="$(mktemp -d)"
    tar -xzf "$cache" -C "$tmpd"
    copy_tree_contents "$tmpd" "$PREFIX/gradle-home"
    rm -rf "$tmpd"
  fi
}

install_rust_assets() {
  local assets_dir="$1"
  local archive cargo_home rustup_home name bin
  archive="$assets_dir/rust/rust-toolchain-${ARCH}.tar.gz"
  [ -f "$archive" ] || return 0

  log "Installing Rust toolchain/cache"
  if [ "$FORCE" = "yes" ]; then
    rm -rf "$PREFIX/rust/cargo" "$PREFIX/rust/rustup"
  fi
  mkdir -p "$PREFIX/rust"
  tar -xzf "$archive" -C "$PREFIX/rust"

  cargo_home="$PREFIX/rust/cargo"
  rustup_home="$PREFIX/rust/rustup"

  if [ -d "$cargo_home/bin" ]; then
    for bin in "$cargo_home"/bin/*; do
      [ -x "$bin" ] || continue
      name="$(basename "$bin")"
      cat > "$PREFIX/bin/$name" <<EOF_RUST_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export CARGO_HOME="$cargo_home"
export RUSTUP_HOME="$rustup_home"
export PATH="$cargo_home/bin:\$PATH"
exec "$bin" "\$@"
EOF_RUST_WRAPPER
      chmod +x "$PREFIX/bin/$name"
    done
  fi
}

patch_php_prefix_text() {
  local php_home="$1"
  local file escaped
  escaped="$(printf '%s' "$php_home" | sed -e 's/[\\&/#]/\\&/g')"
  while IFS= read -r -d '' file; do
    if command -v file >/dev/null 2>&1 && ! file "$file" 2>/dev/null | grep -qi 'text\|script\|php\|perl\|shell'; then
      continue
    fi
    sed -i "s#__OFFLINE_PHP_PREFIX__#$escaped#g" "$file" 2>/dev/null || true
    sed -i "s#/opt/offline/php-[0-9][^/: \"']*#$escaped#g" "$file" 2>/dev/null || true
  done < <(find "$php_home/bin" "$php_home/etc" -type f -print0 2>/dev/null || true)
}

target_php_extension_loaded() {
  local php_bin="$1"
  local php_home="$2"
  local module="$3"

  PHPRC="$php_home/etc" \
  PHP_INI_SCAN_DIR="$php_home/etc/conf.d" \
  LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}" \
    "$php_bin" -m 2>/dev/null \
      | awk -v want="$module" '
          function norm(s) {
            s=tolower(s)
            gsub(/_/, " ", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
          }
          BEGIN { want=norm(want); found=0 }
          /^\[/ { next }
          {
            line=norm($0)
            if (want == "opcache" || want == "zend opcache") {
              if (line == "opcache" || line == "zend opcache") found=1
            } else if (line == want) {
              found=1
            }
          }
          END { exit(found ? 0 : 1) }
        '
}
target_php_zts_enabled() {
  local php_bin="$1"
  local php_home="$2"
  PHPRC="$php_home/etc"   PHP_INI_SCAN_DIR="$php_home/etc/conf.d"   LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}"     "$php_bin" -i 2>/dev/null       | awk -F'=> ' '
          BEGIN { found=0 }
          tolower($1) ~ /thread safety/ {
            value=tolower($2)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /enabled/) found=1
          }
          END { exit(found ? 0 : 1) }
        '
}

validate_target_php_extensions() {
  local php_home="$1"
  local php_bin="$php_home/bin/php"
  local required_file="$php_home/OFFLINE_PHP_REQUIRED_EXTENSIONS"
  local module missing=()
  local thread_safety

  [ -x "$php_bin" ] || { log "Installed PHP missing binary: $php_bin"; exit 1; }
  [ -f "$required_file" ] || { log "PHP required-extension manifest not found: $required_file"; exit 1; }

  thread_safety="$(PHPRC="$php_home/etc" PHP_INI_SCAN_DIR="$php_home/etc/conf.d" LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}" "$php_bin" -i 2>/dev/null | awk -F'=> ' '/Thread Safety/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
  log "PHP thread safety: ${thread_safety:-unknown}"

  if awk 'tolower($0)=="parallel" || tolower($0)=="pthreads" {found=1} END{exit(found?0:1)}' "$required_file" \
     || { [ -f "$php_home/OFFLINE_PHP_REQUIRE_ZTS" ] && grep -qx 'yes' "$php_home/OFFLINE_PHP_REQUIRE_ZTS"; }; then
    if ! target_php_zts_enabled "$php_bin" "$php_home"; then
      log "PHP parallel/ZTS support is required but installed PHP is not ZTS-enabled"
      exit 1
    fi
  fi

  if [ -f "$php_home/OFFLINE_PHP_REQUIRE_OPCACHE" ] && grep -qx 'yes' "$php_home/OFFLINE_PHP_REQUIRE_OPCACHE"; then
    if ! target_php_extension_loaded "$php_bin" "$php_home" "Zend OPcache"; then
      missing+=("Zend OPcache")
    fi
  fi

  while IFS= read -r module; do
    module="$(printf '%s' "$module" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$module" ] || continue
    if ! target_php_extension_loaded "$php_bin" "$php_home" "$module"; then
      missing+=("$module")
    fi
  done < "$required_file"

  if [ "${#missing[@]}" -gt 0 ]; then
    log "Missing installed PHP extension(s): ${missing[*]}"
    log "Loaded PHP modules are:"
    PHPRC="$php_home/etc" PHP_INI_SCAN_DIR="$php_home/etc/conf.d" LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}" "$php_bin" -m >&2 || true
    exit 1
  fi

  PHPRC="$php_home/etc" PHP_INI_SCAN_DIR="$php_home/etc/conf.d" LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}" "$php_bin" -r 'new DOMDocument(); $w = new XMLWriter(); $w->openMemory(); $w->startDocument("1.0", "UTF-8"); $w->startElement("root"); $w->endElement(); $w->endDocument(); $x = simplexml_load_string("<root/>"); if (!$x) { exit(11); }' >/dev/null
  if target_php_extension_loaded "$php_bin" "$php_home" parallel; then
    PHPRC="$php_home/etc" PHP_INI_SCAN_DIR="$php_home/etc/conf.d" LD_LIBRARY_PATH="$php_home/runtime-libs:${LD_LIBRARY_PATH:-}" "$php_bin" -r 'use parallel\Runtime; $r = new Runtime(); $f = $r->run(function(){ return 42; }); if ($f->value() !== 42) { exit(12); }' >/dev/null
  fi

  log "Validated PHP required extensions from $required_file"
}

install_php_assets() {
  local assets_dir="$1"
  local archive tmpd topdir php_home ext_dir composer_phar composer_home_tgz composer_cache_tgz tool
  shopt -s nullglob
  archive=""
  for archive in "$assets_dir"/php/php-*-${ARCH}.tar.gz; do :; done
  shopt -u nullglob
  [ -n "$archive" ] || return 0

  log "Installing PHP from $(basename "$archive")"
  tmpd="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmpd"
  topdir="$(find "$tmpd" -maxdepth 1 -mindepth 1 -type d -name 'php-*' | head -n1 || true)"
  if [ -z "$topdir" ]; then
    log "Could not find PHP topdir in $archive"
    rm -rf "$tmpd"
    exit 1
  fi

  php_home="$PREFIX/php/$(basename "$topdir")"
  if [ -e "$php_home" ] && [ "$FORCE" != "yes" ]; then
    log "Keeping existing PHP: $php_home"
  else
    rm -rf "$php_home"
    mv "$topdir" "$php_home"
  fi
  rm -rf "$tmpd"

  patch_php_prefix_text "$php_home"

  mkdir -p "$php_home/etc/conf.d"
  ext_dir="$(find "$php_home/lib/php/extensions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1 || true)"
  if [ -n "$ext_dir" ]; then
    cat > "$php_home/etc/conf.d/01-extension-dir.ini" <<EOF_PHP_EXTDIR
extension_dir = "$ext_dir"
EOF_PHP_EXTDIR
  fi

  cat > "$PREFIX/bin/php" <<EOF_PHP_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
PHP_HOME="$php_home"
export PHPRC="\$PHP_HOME/etc"
export PHP_INI_SCAN_DIR="\$PHP_HOME/etc/conf.d"
if [ -d "\$PHP_HOME/runtime-libs" ]; then
  export LD_LIBRARY_PATH="\$PHP_HOME/runtime-libs:\${LD_LIBRARY_PATH:-}"
fi
exec "\$PHP_HOME/bin/php" "\$@"
EOF_PHP_WRAPPER
  chmod +x "$PREFIX/bin/php"

  for tool in phpize php-config pecl pear phpdbg php-cgi php-fpm; do
    if [ -x "$php_home/bin/$tool" ]; then
      cat > "$PREFIX/bin/$tool" <<EOF_PHP_TOOL
#!/usr/bin/env bash
set -euo pipefail
PHP_HOME="$php_home"
export PHPRC="\$PHP_HOME/etc"
export PHP_INI_SCAN_DIR="\$PHP_HOME/etc/conf.d"
if [ -d "\$PHP_HOME/runtime-libs" ]; then
  export LD_LIBRARY_PATH="\$PHP_HOME/runtime-libs:\${LD_LIBRARY_PATH:-}"
fi
exec "\$PHP_HOME/bin/$tool" "\$@"
EOF_PHP_TOOL
      chmod +x "$PREFIX/bin/$tool"
    fi
  done

  validate_target_php_extensions "$php_home"

  composer_phar="$(find "$assets_dir/composer" -maxdepth 1 -type f \( -name 'composer-*.phar' -o -name 'composer-latest.phar' \) | sort | tail -n1 || true)"
  if [ -n "$composer_phar" ]; then
    mkdir -p "$PREFIX/php/composer"
    cp "$composer_phar" "$PREFIX/php/composer/composer.phar"
    cat > "$PREFIX/bin/composer" <<EOF_COMPOSER
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"
exec "$PREFIX/bin/php" "$PREFIX/php/composer/composer.phar" "\$@"
EOF_COMPOSER
    chmod +x "$PREFIX/bin/composer"
    ln -sfn "$PREFIX/bin/composer" "$PREFIX/bin/composer.phar"
  fi

  composer_home_tgz="$assets_dir/composer/composer-home-${ARCH}.tar.gz"
  composer_cache_tgz="$assets_dir/composer/composer-cache-${ARCH}.tar.gz"
  if [ -f "$composer_home_tgz" ]; then
    mkdir -p "$PREFIX/php/composer-home"
    tar -xzf "$composer_home_tgz" -C "$PREFIX/php/composer-home"
  fi
  if [ -f "$composer_cache_tgz" ]; then
    mkdir -p "$PREFIX/php/composer-cache"
    tar -xzf "$composer_cache_tgz" -C "$PREFIX/php/composer-cache"
  fi

  if [ -d "$PREFIX/php/composer-home/vendor/bin" ]; then
    for tool in "$PREFIX/php/composer-home"/vendor/bin/*; do
      [ -e "$tool" ] || continue
      ln -sfn "$tool" "$PREFIX/bin/$(basename "$tool")"
    done
  fi

  validate_target_php_extensions "$php_home"
}

copy_templates_and_metadata_from_module() {
  local module_dir="$1"
  copy_tree_contents "$module_dir/templates" "$PREFIX/templates"
  copy_tree_contents "$module_dir/metadata" "$PREFIX/metadata"
}

write_env_file() {
  local env_file="$PREFIX/env.sh"
  local default_java_home="$PREFIX/jdks/jdk-$DEFAULT_JDK_V"
  local highest_jdk=""
  local php_home=""
  local version jdk

  if [ ! -x "$default_java_home/bin/java" ]; then
    highest_jdk="$(find "$PREFIX/jdks" -maxdepth 1 -mindepth 1 -type d -name 'jdk-*' | sort -V 2>/dev/null | tail -n1 || true)"
    [ -n "$highest_jdk" ] && default_java_home="$highest_jdk"
  fi

  php_home="$(find "$PREFIX/php" -maxdepth 1 -mindepth 1 -type d -name 'php-*' | sort -V 2>/dev/null | tail -n1 || true)"

  {
    printf 'export OFFLINE_TOOLCHAIN_HOME=%q\n' "$PREFIX"
    printf 'export GRADLE_USER_HOME=%q\n' "$PREFIX/gradle-home"
    printf 'export CARGO_HOME=%q\n' "$PREFIX/rust/cargo"
    printf 'export RUSTUP_HOME=%q\n' "$PREFIX/rust/rustup"
    printf 'export OFFLINE_LLVM_HOME=%q\n' "$PREFIX/cxx/current/llvm"
    printf 'export OFFLINE_IAC_HOME=%q\n' "$PREFIX/iac/current"
    printf 'export OFFLINE_CMAKE_HOME=%q\n' "$PREFIX/cxx/current/cmake"
    printf 'export COMPOSER_HOME=%q\n' "$PREFIX/php/composer-home"
    printf 'export COMPOSER_CACHE_DIR=%q\n' "$PREFIX/php/composer-cache"
    printf 'export COREPACK_HOME=%q\n' "$PREFIX/node/corepack-home"
    printf 'export NPM_CONFIG_CACHE=%q\n' "$PREFIX/node/npm-cache"
    printf 'export PNPM_STORE_DIR=%q\n' "$PREFIX/node/pnpm-store"
    printf 'export YARN_CACHE_FOLDER=%q\n' "$PREFIX/node/yarn-cache"
    printf 'export OFFLINE_PYTHON_WHEELHOUSE=%q\n' "$PREFIX/python/wheelhouse"
    if [ -n "$php_home" ]; then
      printf 'export PHP_HOME=%q\n' "$php_home"
      printf 'export PHPRC=%q\n' "$php_home/etc"
      printf 'export PHP_INI_SCAN_DIR=%q\n' "$php_home/etc/conf.d"
      printf 'if [ -d "$PHP_HOME/runtime-libs" ]; then export LD_LIBRARY_PATH="$PHP_HOME/runtime-libs:${LD_LIBRARY_PATH:-}"; fi\n'
    fi
    if [ -x "$default_java_home/bin/java" ]; then
      printf 'export JAVA_HOME=%q\n' "$default_java_home"
    fi
    for jdk in "$PREFIX"/jdks/jdk-*; do
      [ -d "$jdk" ] || continue
      version="$(basename "$jdk" | sed 's/^jdk-//')"
      printf 'export JAVA_HOME_%s=%q\n' "$version" "$jdk"
    done
    printf 'export PATH=%q/bin:${CARGO_HOME:-%q/rust/cargo}/bin:${JAVA_HOME:-%q}/bin:$PATH\n' "$PREFIX" "$PREFIX" "$default_java_home"
    cat <<'EOF_ENV_FUNCS'

list-java() {
  local jdk version
  for jdk in "$OFFLINE_TOOLCHAIN_HOME"/jdks/jdk-*; do
    [ -d "$jdk" ] || continue
    version="$(basename "$jdk" | sed 's/^jdk-//')"
    printf '%s\t%s\n' "$version" "$jdk"
  done
}

switch-java() {
  local version="${1:-}"
  local target=""
  if [ -z "$version" ]; then
    echo "Usage: switch-java {version|latest}" >&2
    return 2
  fi
  if [ "$version" = "latest" ]; then
    target="$(find "$OFFLINE_TOOLCHAIN_HOME/jdks" -maxdepth 1 -mindepth 1 -type d -name 'jdk-*' | sort -V 2>/dev/null | tail -n1 || true)"
  else
    target="$OFFLINE_TOOLCHAIN_HOME/jdks/jdk-$version"
  fi
  if [ -z "$target" ] || [ ! -x "$target/bin/java" ] || [ ! -x "$target/bin/javac" ] || [ ! -x "$target/bin/jar" ]; then
    echo "JDK not installed or incomplete: $version" >&2
    return 1
  fi
  export JAVA_HOME="$target"
  case ":$PATH:" in
    *":$JAVA_HOME/bin:"*) ;;
    *) export PATH="$JAVA_HOME/bin:$PATH" ;;
  esac
  export CLASSPATH=".:$JAVA_HOME/lib"
  ln -sfn "$JAVA_HOME/bin/java" "$OFFLINE_TOOLCHAIN_HOME/bin/java" 2>/dev/null || true
  ln -sfn "$JAVA_HOME/bin/javac" "$OFFLINE_TOOLCHAIN_HOME/bin/javac" 2>/dev/null || true
  ln -sfn "$JAVA_HOME/bin/jar" "$OFFLINE_TOOLCHAIN_HOME/bin/jar" 2>/dev/null || true
  echo "Switched to Java $(basename "$JAVA_HOME" | sed 's/^jdk-//') -> JAVA_HOME=$JAVA_HOME"
  java -version
}

use-java() {
  local version="${1:-}"
  if [ -z "$version" ]; then
    echo "Usage: use-java {version|latest} [command ...]" >&2
    return 2
  fi
  shift || true
  switch-java "$version" >/dev/null
  if [ "$#" -eq 0 ]; then
    java -version
  else
    "$@"
  fi
}
EOF_ENV_FUNCS
  } > "$env_file"

  chmod +x "$env_file"
}

write_java_switch_executables() {
  cat > "$PREFIX/bin/use-java" <<'EOF_USE_JAVA'
#!/usr/bin/env bash
set -euo pipefail
PREFIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -lt 1 ]; then
  echo "Usage: use-java {version|latest} [command ...]" >&2
  exit 2
fi
version="$1"
shift
# shellcheck disable=SC1091
source "$PREFIX/env.sh"
switch-java "$version" >/dev/null
if [ $# -eq 0 ]; then
  echo "export JAVA_HOME='$JAVA_HOME'"
  echo "export PATH='$PATH'"
  echo "export CLASSPATH='${CLASSPATH:-}'"
  exit 0
fi
exec "$@"
EOF_USE_JAVA
  chmod +x "$PREFIX/bin/use-java"

  cat > "$PREFIX/bin/switch-java" <<'EOF_SWITCH_JAVA'
#!/usr/bin/env bash
set -euo pipefail
PREFIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PREFIX/env.sh"
switch-java "${1:-}"
echo ""
echo "For the current shell, run: source '$PREFIX/env.sh' && switch-java ${1:-<version>}"
EOF_SWITCH_JAVA
  chmod +x "$PREFIX/bin/switch-java"
}

install_cxx_assets() {
  local assets_dir="$1" archive tool
  shopt -s nullglob
  for archive in "$assets_dir"/cxx/cxx-tooling-*.tar.gz; do
    log "Installing C/C++ tooling from $(basename "$archive")"
    rm -rf "$PREFIX/cxx/current"
    mkdir -p "$PREFIX/cxx/current"
    tar -xzf "$archive" -C "$PREFIX/cxx/current"
  done
  shopt -u nullglob
  [ -d "$PREFIX/cxx/current/bin" ] || { log "C/C++ module did not install bin directory"; exit 1; }
  mkdir -p "$PREFIX/bin"
  while IFS= read -r tool_path; do
    tool="$(basename "$tool_path")"
    ln -sfn "$PREFIX/cxx/current/bin/$tool" "$PREFIX/bin/$tool"
  done < <(find "$PREFIX/cxx/current/bin" -maxdepth 1 -type f -perm -111 | sort)
}


install_node_assets() {
  local assets_dir="$1" archive tmpd topdir version node_home default_home highest="" cache
  shopt -s nullglob
  for archive in "$assets_dir"/node/node-v*-linux-*.tar.xz; do
    tmpd="$(mktemp -d)"; tar -xJf "$archive" -C "$tmpd"
    topdir="$(find "$tmpd" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
    [ -n "$topdir" ] || { log "Node archive has no topdir: $archive"; exit 1; }
    version="$(basename "$topdir" | sed -E 's/^node-v([0-9]+).*/\1/')"
    node_home="$PREFIX/node/node-$version"
    rm -rf "$node_home"; mkdir -p "$PREFIX/node"; mv "$topdir" "$node_home"; rm -rf "$tmpd"
    [ -x "$node_home/bin/node" ] || { log "Installed Node $version missing node"; exit 1; }
    ln -sfn "$node_home/bin/node" "$PREFIX/bin/node$version"
    [ -x "$node_home/bin/npm" ] && ln -sfn "$node_home/bin/npm" "$PREFIX/bin/npm$version"
    [ -x "$node_home/bin/npx" ] && ln -sfn "$node_home/bin/npx" "$PREFIX/bin/npx$version"
    highest="$version"
  done
  shopt -u nullglob
  default_home="$PREFIX/node/node-${DEFAULT_NODE_V:-24}"
  [ -x "$default_home/bin/node" ] || default_home="$PREFIX/node/node-$highest"
  if [ -x "$default_home/bin/node" ]; then
    ln -sfn "$default_home/bin/node" "$PREFIX/bin/node"
    [ -x "$default_home/bin/npm" ] && ln -sfn "$default_home/bin/npm" "$PREFIX/bin/npm"
    [ -x "$default_home/bin/npx" ] && ln -sfn "$default_home/bin/npx" "$PREFIX/bin/npx"
    [ -x "$default_home/bin/corepack" ] && ln -sfn "$default_home/bin/corepack" "$PREFIX/bin/corepack"
  fi
  mkdir -p "$PREFIX/node/corepack-home" "$PREFIX/node/npm-cache" "$PREFIX/node/pnpm-store" "$PREFIX/node/yarn-cache"
  for cache in corepack-home npm-cache pnpm-store yarn-cache; do
    archive="$assets_dir/node/node-${cache}-${ARCH}.tar.gz"
    [ -f "$archive" ] && tar -xzf "$archive" -C "$PREFIX/node/$cache"
  done
  for pm in pnpm yarn; do
    cat > "$PREFIX/bin/$pm" <<EOF_PM
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"
exec "${default_home}/bin/corepack" $pm "\$@"
EOF_PM
    chmod +x "$PREFIX/bin/$pm"
  done
}

install_python_assets() {
  local assets_dir="$1" archive tmpd topdir py_home wheelhouse
  archive="$(find "$assets_dir/python" -maxdepth 1 -type f -name 'python-*.tar.gz' ! -name '*wheelhouse*' | sort | tail -n1 || true)"
  [ -n "$archive" ] || return 0
  tmpd="$(mktemp -d)"; tar -xzf "$archive" -C "$tmpd"
  topdir="$(find "$tmpd" -maxdepth 1 -mindepth 1 -type d -name 'python-*' | head -n1 || true)"
  [ -n "$topdir" ] || { log "Python archive has no topdir"; exit 1; }
  py_home="$PREFIX/python/$(basename "$topdir")"; rm -rf "$py_home"; mkdir -p "$PREFIX/python"; mv "$topdir" "$py_home"; rm -rf "$tmpd"
  mkdir -p "$PREFIX/python/wheelhouse"
  wheelhouse="$assets_dir/python/python-wheelhouse-${ARCH}.tar.gz"
  [ -f "$wheelhouse" ] && tar -xzf "$wheelhouse" -C "$PREFIX/python/wheelhouse"
  for name in python python3 pip pip3; do
    target="$py_home/bin/$name"; [ -x "$target" ] || continue
    cat > "$PREFIX/bin/$name" <<EOF_PY
#!/usr/bin/env bash
set -euo pipefail
PY_HOME="$py_home"
export LD_LIBRARY_PATH="\$PY_HOME/lib:\$PY_HOME/runtime-libs:\${LD_LIBRARY_PATH:-}"
exec "\$PY_HOME/bin/$name" "\$@"
EOF_PY
    chmod +x "$PREFIX/bin/$name"
  done
  cat > "$PREFIX/bin/python-venv-offline" <<EOF_VENV
#!/usr/bin/env bash
set -euo pipefail
DEST="\${1:-.venv}"
"$PREFIX/bin/python3" -m venv "\$DEST"
"\$DEST/bin/python" -m pip install --no-index --find-links "$PREFIX/python/wheelhouse" --upgrade pip setuptools wheel
if [ "\${2:-}" = "-r" ] && [ -n "\${3:-}" ]; then
  "\$DEST/bin/python" -m pip install --no-index --find-links "$PREFIX/python/wheelhouse" -r "\$3"
fi
EOF_VENV
  chmod +x "$PREFIX/bin/python-venv-offline"
}

install_cli_assets() {
  local assets_dir="$1" archive
  archive="$assets_dir/cli/cli-tools-${ARCH}.tar.gz"
  [ -f "$archive" ] || return 0
  rm -rf "$PREFIX/cli/current"; mkdir -p "$PREFIX/cli/current"; tar -xzf "$archive" -C "$PREFIX/cli/current"
  copy_tree_contents "$PREFIX/cli/current/bin" "$PREFIX/bin"
}


install_iac_assets() {
  local assets="$1" archive iac_home
  archive="$(find "$assets/iac" -maxdepth 1 -type f -name 'iac-tools-*.tar.gz' | sort | tail -n1 || true)"
  [ -n "$archive" ] || { log "No IaC tools archive found"; exit 1; }
  iac_home="$PREFIX/iac/current"
  rm -rf "$iac_home"
  mkdir -p "$iac_home"
  tar -xzf "$archive" -C "$iac_home"
  for tool in terraform tflint checkov runway; do
    [ -x "$iac_home/bin/$tool" ] || { log "IaC tool missing after install: $tool"; exit 1; }
    ln -sfn "$iac_home/bin/$tool" "$PREFIX/bin/$tool"
  done
}

install_podman_assets() {
  local assets_dir="$1" archive bin
  archive="$assets_dir/podman/podman-tools-${ARCH}.tar.gz"
  [ -f "$archive" ] || return 0
  rm -rf "$PREFIX/podman/current"; mkdir -p "$PREFIX/podman/current"; tar -xzf "$archive" -C "$PREFIX/podman/current"
  mkdir -p "$PREFIX/bin"
  while IFS= read -r bin; do
    [ -x "$bin" ] || continue
    ln -sfn "$bin" "$PREFIX/bin/$(basename "$bin")"
  done < <(find "$PREFIX/podman/current" \
    \( -type f -o -type l \) -path '*/bin/*' | sort)
  [ -x "$PREFIX/bin/podman" ] && [ "${PODMAN_LINK_DOCKER_ALIAS:-yes}" = "yes" ] && ln -sfn "$PREFIX/bin/podman" "$PREFIX/bin/docker" || true
}

install_images_assets() {
  local assets_dir="$1" archive
  archive="$assets_dir/images/image-archives-${ARCH}.tar.gz"
  [ -f "$archive" ] || return 0
  rm -rf "$PREFIX/images/current"; mkdir -p "$PREFIX/images/current"; tar -xzf "$archive" -C "$PREFIX/images/current"
  copy_tree_contents "$PREFIX/images/current/bin" "$PREFIX/bin"
}

install_one_module() {
  local module="$1"
  extract_module_bundle "$module"
  log "Installing module: $module"
  case "$module" in
    jdk) install_jdk_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    gradle) install_gradle_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    rust) install_rust_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    php) install_php_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    cxx) install_cxx_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    node) install_node_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    python) install_python_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    cli) install_cli_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    iac) install_iac_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    podman) install_podman_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    images) install_images_assets "$EXTRACTED_MODULE_DIR/assets" ;;
    *) log "Unknown module: $module"; exit 2 ;;
  esac
  copy_templates_and_metadata_from_module "$EXTRACTED_MODULE_DIR"
  write_env_file
  write_java_switch_executables
}

validate_installed_modules() {
  local module
  log "Validating installed modules"
  # shellcheck disable=SC1091
  [ -f "$PREFIX/env.sh" ] && source "$PREFIX/env.sh"
  for module in "$@"; do
    case "$module" in
      jdk)
        [ -x "$PREFIX/bin/java" ] || { log "Missing java"; exit 1; }
        [ -x "$PREFIX/bin/javac" ] || { log "Missing javac"; exit 1; }
        [ -x "$PREFIX/bin/jar" ] || { log "Missing jar"; exit 1; }
        "$PREFIX/bin/java" -version 2>&1 | head -n1
        "$PREFIX/bin/javac" -version
        "$PREFIX/bin/jar" --help >/dev/null
        ;;
      gradle)
        [ -x "$PREFIX/bin/gradle" ] || { log "Missing gradle"; exit 1; }
        if [ -x "$PREFIX/bin/java" ] || command -v java >/dev/null 2>&1; then
          "$PREFIX/bin/gradle" --offline --version >/dev/null
        else
          log "Gradle installed; Java not installed in this prefix, skipping Gradle runtime validation"
        fi
        ;;
      rust)
        [ -x "$PREFIX/bin/rustc" ] || { log "Missing rustc"; exit 1; }
        [ -x "$PREFIX/bin/cargo" ] || { log "Missing cargo"; exit 1; }
        "$PREFIX/bin/rustc" --version
        "$PREFIX/bin/cargo" --version
        ;;
      php)
        [ -x "$PREFIX/bin/php" ] || { log "Missing php"; exit 1; }
        "$PREFIX/bin/php" -v | head -n1
        php_home="$(find "$PREFIX/php" -maxdepth 1 -mindepth 1 -type d -name 'php-*' | sort -V 2>/dev/null | tail -n1 || true)"
        [ -n "$php_home" ] || { log "Missing PHP home under $PREFIX/php"; exit 1; }
        validate_target_php_extensions "$php_home"
        if module_bundle_present php && find "$PREFIX/php" -maxdepth 3 -type f -name composer.phar | grep -q .; then
          [ -x "$PREFIX/bin/composer" ] || { log "Missing composer"; exit 1; }
          "$PREFIX/bin/composer" --version
        fi
        ;;
      cxx)
        for tool in clang-format clang-tidy cpplint cmake ctest cpack ninja; do
          [ -x "$PREFIX/bin/$tool" ] || { log "Missing $tool"; exit 1; }
          "$PREFIX/bin/$tool" --version >/dev/null 2>&1 || true
        done
        ;;
      node)
        [ -x "$PREFIX/bin/node" ] || { log "Missing node"; exit 1; }
        "$PREFIX/bin/node" --version
        [ -x "$PREFIX/bin/pnpm" ] && "$PREFIX/bin/pnpm" --version >/dev/null 2>&1 || true
        [ -x "$PREFIX/bin/yarn" ] && "$PREFIX/bin/yarn" --version >/dev/null 2>&1 || true
        ;;
      python)
        [ -x "$PREFIX/bin/python3" ] || { log "Missing python3"; exit 1; }
        "$PREFIX/bin/python3" --version
        [ -x "$PREFIX/bin/pip3" ] || { log "Missing pip3"; exit 1; }
        ;;
      cli)
        for tool in jq yq shellcheck gh k6; do [ -x "$PREFIX/bin/$tool" ] && "$PREFIX/bin/$tool" --version >/dev/null 2>&1 || true; done
        ;;
      iac)
        for tool in terraform tflint checkov runway; do
          [ -x "$PREFIX/bin/$tool" ] || { log "Missing $tool"; exit 1; }
        done
        "$PREFIX/bin/terraform" version >/dev/null
        "$PREFIX/bin/tflint" --version >/dev/null
        "$PREFIX/bin/checkov" --version >/dev/null 2>&1 || "$PREFIX/bin/checkov" --help >/dev/null
        "$PREFIX/bin/runway" --version >/dev/null 2>&1 || "$PREFIX/bin/runway" --help >/dev/null
        ;;
      podman)
        [ -x "$PREFIX/bin/podman5" ] && "$PREFIX/bin/podman5" --version >/dev/null 2>&1 || true
        [ -x "$PREFIX/bin/podman4" ] && "$PREFIX/bin/podman4" --version >/dev/null 2>&1 || true
        ;;
      images)
        [ -x "$PREFIX/bin/podman-load-offline-images" ] || true
        ;;
    esac
  done
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "${1:-}" = "--list" ]; then
  list_modules
  exit 0
fi

modules=()
if [ "$#" -eq 0 ]; then
  while IFS= read -r module; do modules+=("$module"); done < <(list_modules)
elif [ "$#" -eq 1 ] && [ "$1" = "all" ]; then
  while IFS= read -r module; do modules+=("$module"); done < <(list_modules)
else
  modules=("$@")
fi

if [ "${#modules[@]}" -eq 0 ]; then
  log "No module bundles found in $BUNDLE_STORE"
  usage
  exit 1
fi

log "Installing modules into: $PREFIX"
log "Bundle store: $BUNDLE_STORE"
log "Modules: ${modules[*]}"

# Install in dependency-friendly order regardless of argument order.
ordered=()
for preferred in jdk gradle rust php cxx node python cli iac podman images; do
  for module in "${modules[@]}"; do
    [ "$module" = "$preferred" ] && ordered+=("$module")
  done
done

for module in "${ordered[@]}"; do
  install_one_module "$module"
done

validate_installed_modules "${ordered[@]}"

log ""
log "Offline modules installed under: $PREFIX"
log "Activate with:"
log "  source \"$PREFIX/env.sh\""
