#!/usr/bin/env bash
#
# Self-contained installer for ScaleHLS-HIDA and Stream-HLS only.
# Does not depend on the rest of the codesign tree—clones upstream repos
# into INSTALL_ROOT and builds them using the same flow as setup_scripts/
# scale_hls_setup.sh and streamhls_setup.sh.
#
# Usage:
#   ./setup_scale_stream_hls.sh [--prefix DIR] [--all|--scalehls|--streamhls]
#       [--full] [--gui] [--jobs N] [--ampl-uuid UUID]
#
# Environment:
#   INSTALL_ROOT   Same as --prefix (default: ./hls_toolchain)
#   SCALEHLS_REPO  Override ScaleHLS git URL
#   STREAMHLS_REPO Override Stream-HLS git URL
#

set -o pipefail

################## defaults ##################

INSTALL_ROOT="${INSTALL_ROOT:-$(pwd)/hls_toolchain}"
FORCE_FULL=0
DO_SCALE=0
DO_STREAM=0
USE_GUI=0
JOBS=""
AMPL_UUID=""
SUDO_KEEPALIVE_PID=""

SCALEHLS_REPO="${SCALEHLS_REPO:-https://github.com/UIUC-ChenLab/ScaleHLS-HIDA.git}"
STREAMHLS_REPO="${STREAMHLS_REPO:-https://github.com/UCLA-VAST/Stream-HLS.git}"

MINICONDA_INSTALLER_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
AMPL_BOX_URL="https://cmu.box.com/shared/static/n6c6f147vefdrrsedammfqhfhteg7vyt"

MAX_PARALLEL_CORES=24

################## helpers ##################

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: setup_scale_stream_hls.sh [options]

  --prefix DIR     Install root (cloned trees: ScaleHLS-HIDA/, Stream-HLS/).
                   Default: ./hls_toolchain  (or INSTALL_ROOT env)

  --all            Install both ScaleHLS and Stream-HLS (default if no component flags).
  --scalehls       Install only ScaleHLS-HIDA.
  --streamhls      Install only Stream-HLS.

  --full           Force full clone/build (ignore incremental shortcuts).
  --gui            If zenity is available, pick components in a dialog.
  --jobs N         Parallel build jobs (default: min(nproc, 24)).

  --ampl-uuid U    Activate AMPL license after Stream-HLS (optional).

  -h, --help       This help.

Examples:
  ./setup_scale_stream_hls.sh --prefix ~/hls --all --full
  ./setup_scale_stream_hls.sh --streamhls --prefix /tmp/hls
EOF
}

stop_sudo_keepalive() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

start_sudo_keepalive() {
    local keepalive_seconds=28800
    (
        local started_at current_epoch
        started_at=$(date +%s)
        while true; do
            sleep 60
            sudo -n -v 2>/dev/null || exit 0
            current_epoch=$(date +%s)
            if (( current_epoch - started_at >= keepalive_seconds )); then
                exit 0
            fi
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
    trap stop_sudo_keepalive EXIT
}

pick_jobs() {
    local cores
    cores=$(nproc 2>/dev/null || echo 8)
    if [[ -z "$JOBS" ]]; then
        JOBS=$cores
        if [[ "$JOBS" -gt "$MAX_PARALLEL_CORES" ]]; then
            JOBS=$MAX_PARALLEL_CORES
        fi
        if [[ "$JOBS" -lt 1 ]]; then
            JOBS=1
        fi
    fi
}

download_file() {
    local url=$1 dest=$2
    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url" || die "wget failed: $url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL -o "$dest" "$url" || die "curl failed: $url"
    else
        die "Need wget or curl to download files."
    fi
}

ensure_dir() {
    mkdir -p "$1" || die "cannot create $1"
}

run_gui_picker() {
    if ! command -v zenity >/dev/null 2>&1; then
        echo "zenity not found; ignoring --gui."
        return 1
    fi
    local choice
    choice=$(zenity --list --radiolist \
        --title="HLS toolchain setup" \
        --text="Choose what to install:" \
        --column="" --column="Component" \
        TRUE "Both (ScaleHLS + Stream-HLS)" \
        FALSE "ScaleHLS only" \
        FALSE "Stream-HLS only" \
        --height=220 2>/dev/null) || return 1
    case "$choice" in
        *Both*) DO_SCALE=1; DO_STREAM=1 ;;
        *ScaleHLS*) DO_SCALE=1 ;;
        *Stream*) DO_STREAM=1 ;;
        *) return 1 ;;
    esac
    return 0
}

ensure_conda_for_streamhls() {
    if command -v conda >/dev/null 2>&1; then
        local conda_base
        conda_base=$(conda info --base 2>/dev/null) || true
        if [[ -n "$conda_base" && -f "$conda_base/etc/profile.d/conda.sh" ]]; then
            # shellcheck source=/dev/null
            source "$conda_base/etc/profile.d/conda.sh"
        fi
        return 0
    fi

    echo "conda not found; installing Miniconda into $INSTALL_ROOT/miniconda3 ..."
    ensure_dir "$INSTALL_ROOT"
    local installer="$INSTALL_ROOT/Miniconda3-latest-Linux-x86_64.sh"
    if [[ ! -f "$installer" ]]; then
        download_file "$MINICONDA_INSTALLER_URL" "$installer"
    fi
    bash "$installer" -b -p "$INSTALL_ROOT/miniconda3" || die "Miniconda install failed"
    rm -f "$installer"
    # shellcheck source=/dev/null
    source "$INSTALL_ROOT/miniconda3/etc/profile.d/conda.sh"
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
}

ensure_python311_for_scalehls() {
    if command -v python3.11 >/dev/null 2>&1; then
        return 0
    fi
    die "python3.11 is required for ScaleHLS (Torch-MLIR venv). Install python3.11 (e.g. \
sudo yum install -y python3.11 on RHEL 8+) and re-run."
}

maybe_sudo_prompt() {
    local need_sudo=0
    if [[ "$DO_SCALE" -eq 1 ]] && ! command -v lld >/dev/null 2>&1; then
        need_sudo=1
    fi
    if [[ "$need_sudo" -eq 1 ]]; then
        echo "Elevated permissions may be required (e.g. to install lld). Enter sudo password if prompted."
        sudo -v || die "sudo required"
        start_sudo_keepalive
        echo "sudo credentials will be refreshed periodically during long builds."
    fi
}

install_lld_if_missing() {
    if command -v lld >/dev/null 2>&1; then
        echo "[scalehls] lld already on PATH."
        return 0
    fi
    echo "[scalehls] Installing lld (linker)..."
    if [[ -f /etc/redhat-release ]]; then
        sudo yum install -y lld || die "failed to install lld"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y lld || die "failed to install lld"
    else
        die "Please install the LLVM lld package for your OS, then re-run."
    fi
}

# True when prior build-scalehls.sh run completed (LLVM + Polygeist trees configured).
scalehls_build_present() {
    local d=$1
    [[ -f "$d/build/CMakeCache.txt" ]] && [[ -f "$d/polygeist/build/CMakeCache.txt" ]]
}

################## parse args ##################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            INSTALL_ROOT="$2"
            shift 2
            ;;
        --full)
            FORCE_FULL=1
            shift
            ;;
        --all)
            DO_SCALE=1
            DO_STREAM=1
            shift
            ;;
        --scalehls)
            DO_SCALE=1
            shift
            ;;
        --streamhls)
            DO_STREAM=1
            shift
            ;;
        --gui)
            USE_GUI=1
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --ampl-uuid)
            AMPL_UUID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

if [[ "$USE_GUI" -eq 1 ]]; then
    if ! run_gui_picker; then
        echo "GUI picker failed or cancelled; install zenity or use --scalehls / --streamhls / --all."
    fi
fi

if [[ "$DO_SCALE" -eq 0 && "$DO_STREAM" -eq 0 ]]; then
    DO_SCALE=1
    DO_STREAM=1
fi

pick_jobs
start_time=$(date +%s)

echo ">>> HLS toolchain setup"
echo "    INSTALL_ROOT: $INSTALL_ROOT"
echo "    Components:   scale=$DO_SCALE stream=$DO_STREAM  force_full=$FORCE_FULL  jobs=$JOBS"
echo ""

ensure_dir "$INSTALL_ROOT"
INSTALL_ROOT="$(cd "$INSTALL_ROOT" && pwd)"
cd "$INSTALL_ROOT" || die "cannot cd to $INSTALL_ROOT"

maybe_sudo_prompt

################## ScaleHLS ##################

if [[ "$DO_SCALE" -eq 1 ]]; then
    echo "========== ScaleHLS-HIDA =========="
    SCALE_DIR="$INSTALL_ROOT/ScaleHLS-HIDA"

    if [[ "$FORCE_FULL" -eq 1 ]] || [[ ! -d "$SCALE_DIR/.git" ]]; then
        if [[ -d "$SCALE_DIR" ]]; then
            echo "[scalehls] Removing incomplete or non-git tree at $SCALE_DIR"
            rm -rf "$SCALE_DIR"
        fi
        echo "[scalehls] Cloning $SCALEHLS_REPO ..."
        git clone --recurse-submodules "$SCALEHLS_REPO" "$SCALE_DIR" || die "clone ScaleHLS-HIDA failed"
    else
        echo "[scalehls] Existing repo at $SCALE_DIR — fetching updates (use --full to re-clone)."
        git -C "$SCALE_DIR" pull || true
        git -C "$SCALE_DIR" submodule sync --recursive
        git -C "$SCALE_DIR" submodule update --init --recursive
    fi

    install_lld_if_missing

    if [[ "$FORCE_FULL" -eq 1 ]] || ! scalehls_build_present "$SCALE_DIR"; then
        echo "[scalehls] Building (this can take a long time)..."
        ( cd "$SCALE_DIR" && bash ./build-scalehls.sh -j"$JOBS" ) || die "ScaleHLS build failed"
    else
        echo "[scalehls] Existing LLVM/Polygeist build trees found; skipping compile (use --full to rebuild)."
    fi

    ensure_python311_for_scalehls

    if [[ ! -f "$SCALE_DIR/.gitignore" ]] || ! grep -q "mlir_venv/" "$SCALE_DIR/.gitignore" 2>/dev/null; then
        echo "mlir_venv/" >> "$SCALE_DIR/.gitignore"
    fi

    if [[ ! -d "$SCALE_DIR/mlir_venv" ]] || [[ "$FORCE_FULL" -eq 1 ]]; then
        if [[ -d "$SCALE_DIR/mlir_venv" && "$FORCE_FULL" -eq 1 ]]; then
            rm -rf "$SCALE_DIR/mlir_venv"
        fi
        echo "[scalehls] Creating Torch-MLIR virtualenv..."
        ( cd "$SCALE_DIR"
          python3.11 -m venv mlir_venv
          # shellcheck source=/dev/null
          source mlir_venv/bin/activate
          python3.11 -m pip install --upgrade pip
          pip install --no-deps -r requirements.txt
          deactivate
        ) || die "ScaleHLS Python venv setup failed"
    else
        echo "[scalehls] mlir_venv already present (delete mlir_venv or use --full to rebuild)."
    fi

    if [[ "$FORCE_FULL" -eq 1 ]]; then
        ( cd "$SCALE_DIR"
          # shellcheck source=/dev/null
          source mlir_venv/bin/activate
          python - <<'PY'
import torch, torchvision
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("cuda available:", torch.cuda.is_available())
PY
          deactivate
        ) || true
    fi

    cat > "$INSTALL_ROOT/source_scalehls_env.sh" <<EOF
# Source this file to use ScaleHLS tools from: $SCALE_DIR
export PATH="$SCALE_DIR/build/bin:$SCALE_DIR/polygeist/build/bin:\$PATH"
export PYTHONPATH="$SCALE_DIR/build/tools/scalehls/python_packages/scalehls_core\${PYTHONPATH:+:\$PYTHONPATH}"
# Optional Torch-MLIR venv: source $SCALE_DIR/mlir_venv/bin/activate
echo "ScaleHLS PATH and PYTHONPATH configured."
EOF
    echo "[scalehls] Wrote $INSTALL_ROOT/source_scalehls_env.sh"
    echo "========== ScaleHLS done =========="
fi

################## Stream-HLS ##################

if [[ "$DO_STREAM" -eq 1 ]]; then
    echo "========== Stream-HLS =========="
    STREAM_DIR="$INSTALL_ROOT/Stream-HLS"
    LLVM_DIR="$STREAM_DIR/extern/llvm-project"

    ensure_conda_for_streamhls

    if [[ "$FORCE_FULL" -eq 1 ]] || [[ ! -d "$STREAM_DIR/.git" ]]; then
        if [[ -d "$STREAM_DIR" ]]; then
            echo "[streamhls] Removing incomplete tree at $STREAM_DIR"
            rm -rf "$STREAM_DIR"
        fi
        echo "[streamhls] Cloning $STREAMHLS_REPO ..."
        git clone --recurse-submodules "$STREAMHLS_REPO" "$STREAM_DIR" || die "clone Stream-HLS failed"
    else
        echo "[streamhls] Existing repo at $STREAM_DIR — pulling (use --full to re-clone)."
        git -C "$STREAM_DIR" pull || true
        git -C "$STREAM_DIR" submodule sync
        git -C "$STREAM_DIR" submodule update --init --recursive
    fi

    # Patch Stream-HLS source before configure so CMake sees the dependency
    # in the same run that generates build files.
    SUPPORT_CMAKE="$STREAM_DIR/lib/Support/CMakeLists.txt"
    if [[ -f "$SUPPORT_CMAKE" ]]; then
        if ! grep -q "MLIRDataflowIncGen" "$SUPPORT_CMAKE" 2>/dev/null; then
            echo "[streamhls] Patching $SUPPORT_CMAKE to depend on Dataflow inc generation."
            sed -i '/${globbed}/a \\  DEPENDS\n\\  MLIRDataflowIncGen\n\\  MLIRDataflowAttributesIncGen\n\\  MLIRDataflowInterfacesIncGen' "$SUPPORT_CMAKE" || die "Failed to patch $SUPPORT_CMAKE"
        fi
    fi

    cd "$STREAM_DIR" || die "cd Stream-HLS"

    if [[ ! -d "ampl.linux-intel64" ]]; then
        echo "[streamhls] Downloading AMPL bundle..."
        if command -v wget >/dev/null 2>&1; then
            wget -O ampl_package.tar.gz "$AMPL_BOX_URL" || die "wget failed to download AMPL: $AMPL_BOX_URL"
        elif command -v curl >/dev/null 2>&1; then
            curl -fL -o ampl_package.tar.gz "$AMPL_BOX_URL" || die "curl failed to download AMPL: $AMPL_BOX_URL"
        else
            die "Need wget or curl to download AMPL bundle."
        fi
        
        tar -xzf ampl_package.tar.gz || die "Failed to extract AMPL bundle"
        rm -f ampl_package.tar.gz
        [[ -d "ampl.linux-intel64" ]] || die "AMPL directory missing after extraction"
        echo "[streamhls] AMPL bundle downloaded and extracted successfully."
    else
        echo "[streamhls] ampl.linux-intel64 already present."
    fi

    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true

    if [[ "$FORCE_FULL" -eq 1 ]] || [[ ! -f "$LLVM_DIR/build/CMakeCache.txt" ]]; then
        echo "[streamhls] Building LLVM/MLIR in extern/llvm-project ..."
        mkdir -p "$LLVM_DIR/build" || die "cannot create LLVM build dir"
        LLVM_CMAKE_GENERATOR="Unix Makefiles"
        if command -v ninja >/dev/null 2>&1; then
            LLVM_CMAKE_GENERATOR="Ninja"
        fi
        LLVM_CC="$(command -v clang 2>/dev/null || true)"
        LLVM_CXX="$(command -v clang++ 2>/dev/null || true)"
        if [[ -z "$LLVM_CC" || -z "$LLVM_CXX" ]]; then
            die "clang and clang++ are required to build LLVM/MLIR"
        fi
        ( cd "$LLVM_DIR/build" && cmake -G "$LLVM_CMAKE_GENERATOR" ../llvm \
            -DLLVM_ENABLE_PROJECTS=mlir \
            -DCMAKE_BUILD_TYPE=Debug \
            -DLLVM_ENABLE_ASSERTIONS=ON \
            -DCMAKE_C_COMPILER="$LLVM_CC" \
            -DCMAKE_CXX_COMPILER="$LLVM_CXX" \
            -DCMAKE_ASM_COMPILER="$LLVM_CC" \
            -DLLVM_ENABLE_LLD=ON \
            -DLLVM_INSTALL_UTILS=ON \
          && if [[ "$LLVM_CMAKE_GENERATOR" == "Ninja" ]]; then \
                cmake --build . --target check-mlir -j"$JOBS"; \
             else \
                cmake --build . --target check-mlir -- -j"$JOBS"; \
             fi ) || die "LLVM/MLIR build failed"
    else
        echo "[streamhls] LLVM/MLIR build tree found; skipping LLVM rebuild (use --full to rebuild)."
    fi

    if [[ "$FORCE_FULL" -eq 1 ]] || [[ ! -f "$STREAM_DIR/build/CMakeCache.txt" ]]; then
        echo "[streamhls] Configuring Stream-HLS ..."
        ( cd "$STREAM_DIR" && bash ./build-streamhls.sh "$LLVM_DIR" ) || die "Stream-HLS configure failed"
    else
        echo "[streamhls] Stream-HLS build tree found; reusing existing configuration (use --full to reconfigure)."
    fi

    # Force-generate Dataflow tablegen outputs before the full build so the
    # generated header streamhls/Dialect/Dataflow/DataflowDialect.h.inc exists.
    echo "[streamhls] Generating Dataflow TableGen headers ..."
    ( cd "$STREAM_DIR/build" && cmake --build . \
        --target MLIRDataflowIncGen MLIRDataflowAttributesIncGen MLIRDataflowInterfacesIncGen \
        -- -j"$JOBS" ) || die "Stream-HLS Dataflow tablegen generation failed"

    if [[ "$FORCE_FULL" -eq 1 ]] || [[ ! -x "$STREAM_DIR/build/bin/streamhls-opt" ]]; then
        echo "[streamhls] Building Stream-HLS ..."
        ( cd "$STREAM_DIR/build" && cmake --build . -- -j"$JOBS" ) || die "Stream-HLS build failed"
    else
        echo "[streamhls] streamhls-opt already present; skipping Stream-HLS compile (use --full to rebuild)."
    fi

    if [[ -z "$AMPL_UUID" ]] && [[ -t 0 ]] && [[ -r /dev/tty ]]; then
        echo -n "Enter AMPL license UUID (optional, press Enter to skip): " >/dev/tty
        read -r AMPL_UUID </dev/tty || true
    fi

    if [[ -n "$AMPL_UUID" ]]; then
        if [[ -d "$STREAM_DIR/ampl.linux-intel64" ]]; then
            echo "[streamhls] Activating AMPL license..."
            ( cd "$STREAM_DIR/ampl.linux-intel64" && ./ampl <<EOF
shell "amplkey activate --uuid $AMPL_UUID";
exit;
EOF
            ) || echo "[streamhls] AMPL activation reported an error; you can run ampl manually later."
        else
            echo "[streamhls] WARNING: Cannot activate AMPL UUID; AMPL directory not found."
            echo "[streamhls] If you have AMPL, manually extract it to $STREAM_DIR/ampl.linux-intel64 and activate."
        fi
    else
        echo "[streamhls] Skipped AMPL UUID activation (pass --ampl-uuid or enter when prompted)."
    fi

    cat > "$INSTALL_ROOT/source_streamhls_env.sh" <<EOF
# Generated for Stream-HLS at $STREAM_DIR — run: source $INSTALL_ROOT/source_streamhls_env.sh
if [[ -f "$INSTALL_ROOT/miniconda3/etc/profile.d/conda.sh" ]]; then
  # shellcheck source=/dev/null
  source "$INSTALL_ROOT/miniconda3/etc/profile.d/conda.sh"
elif command -v conda >/dev/null 2>&1; then
  __streamhls_conda_base=\$(conda info --base 2>/dev/null)
  if [[ -n "\$__streamhls_conda_base" && -f "\$__streamhls_conda_base/etc/profile.d/conda.sh" ]]; then
    # shellcheck source=/dev/null
    source "\$__streamhls_conda_base/etc/profile.d/conda.sh"
  fi
  unset __streamhls_conda_base
fi
conda activate streamhls 2>/dev/null || true
export ROOT_DIR="$STREAM_DIR"
export PATH="\$PATH:\$ROOT_DIR/build/bin:\$ROOT_DIR/ampl.linux-intel64"
export LD_LIBRARY_PATH="\$ROOT_DIR/ampl.linux-intel64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
echo "Stream-HLS env ready (ROOT_DIR=\$ROOT_DIR)"
EOF

    echo "[streamhls] Wrote $INSTALL_ROOT/source_streamhls_env.sh"
    echo "========== Stream-HLS done =========="
fi

################## summary ##################

end_time=$(date +%s)
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))

echo ""
echo "SETUP COMPLETE"
echo "  Root:     $INSTALL_ROOT"
[[ "$DO_SCALE" -eq 1 ]] && echo "  ScaleHLS: source $INSTALL_ROOT/source_scalehls_env.sh"
[[ "$DO_STREAM" -eq 1 ]] && echo "  Stream:   source $INSTALL_ROOT/source_streamhls_env.sh"
printf "  Elapsed:  %d min %d sec\n" "$minutes" "$seconds"
echo ""

exit 0
