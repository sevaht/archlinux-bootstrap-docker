# NOTE: Because running in a container, "landlock" is not supported the pacman
# sandbox filesystem is disabled.
FROM alpine AS bootstrap
ARG MIRRORS=" \
    https://geo.mirror.pkgbuild.com \
    https://mirror.rackspace.com/archlinux \
    https://mirror.leaseweb.net/archlinux \
"
RUN set -euo pipefail \
    && apk add --no-cache zstd wget ca-certificates \
    && tarzst="archlinux-bootstrap-x86_64.tar.zst" \
    && checksums="sha256sums.txt" \
    && for mirror_url in ${MIRRORS}; do \
        if wget -qO "${checksums}" "${mirror_url}/iso/latest/${checksums}" \
            && wget -qO "${tarzst}" "${mirror_url}/iso/latest/${tarzst}" \
            && sha256sum "${tarzst}" | grep -qFxf - "${checksums}" \
        ; then \
            mkdir /rootfs \
            && zstd -dc "${tarzst}" | tar \
                --extract -f - --strip-components=1 --numeric-owner \
                -C /rootfs \
            && rm -f "${tarzst}" "${checksums}" /rootfs/README \
            && printf 'Server = %s/$repo/os/$arch\n' ${MIRRORS} \
                > /rootfs/etc/pacman.d/mirrorlist \
            && exit 0 \
        ; fi \
    done \
    && echo "no mirror had a valid tarball" >&2 \
    && exit 1

FROM scratch AS base
ARG LOCALE_LANG="en_US.UTF-8"
COPY --from=bootstrap /rootfs/ /
RUN set -euo pipefail \
    && pacman-key --init \
    && pacman-key --populate archlinux \
    && sed -E 's/^#(DisableSandboxFilesystem)$/\1/' -i /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed base \
    && sed "s/^#\(${LOCALE_LANG}\( \|$\)\)/\1/" -i /etc/locale.gen \
    && locale-gen \
    && echo "LANG=${LOCALE_LANG}" > /etc/locale.conf \
    && setcap cap_net_raw+ep /usr/bin/ping \
    && pacman -Sc --noconfirm
CMD ["/bin/bash"]

FROM base AS final
ARG ADMIN_USER=tux
ARG WSL_HOSTNAME
ARG NO_DOCKER_GROUP
ARG NO_BASHRC
ARG NO_DEV_TOOLS
ARG NO_CROSS_DEV_TOOLS
ARG NO_NEOVIM_CONFIG
ARG NO_YAY
# installs 'python-wheel' early so python packages are tidier on disk
RUN set -euo pipefail \
    && pacman -S --noconfirm --needed python python-wheel \
    && pacman -S --noconfirm --needed \
        python-pip python-virtualenv uv python-requests tk \
        reflector pacman-contrib \
        sudo git vifm neovim fd \
        keychain openssh lsof \
        diffutils colordiff less \
        zip unzip fuse-zip \
    && echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel \
    && echo 'Defaults passwd_timeout=0' > /etc/sudoers.d/disable_timeout \
    && useradd -G wheel -m "${ADMIN_USER}" \
    && printf '%s:%s' "${ADMIN_USER}" 'archlinux' | chpasswd \
    && if [ -z "${NO_DOCKER_GROUP:-}" ]; then \
        groupadd docker \
        && usermod -aG docker "${ADMIN_USER}" \
    ; fi \
    && if [ -n "${WSL_HOSTNAME:-}" ]; then \
        printf '%s\n' \
            '[network]' "hostname=${WSL_HOSTNAME}" \
            '' \
            '[user]' "default=${ADMIN_USER}" \
            > /etc/wsl.conf \
    ; fi \
    && sed 's/^\(\s*set vicmd=\)vim\(\s*\)$/\1nvim\2/' \
            -i /usr/share/vifm/vifmrc \
    && if [ -z "${NO_BASHRC:-}" ]; then \
        bashrc_git=https://github.com/nacitar/bashrc.git \
        && su "${ADMIN_USER}" -c "set -euo pipefail \
                && git clone '${bashrc_git}' \"\${HOME}/.bash\" \
                && rm ~/.bashrc \
                && \"\${HOME}/.bash/install.sh\" \
            " \
    ; else \
        su "${ADMIN_USER}" -c "python -m pipx ensurepath" \
    ; fi \
    && if [ -z "${NO_DEV_TOOLS:-}" ]; then \
        pacman -S --noconfirm --needed \
                base-devel clang cmake ccache doxygen uv \
                shfmt shellcheck \
        && su "${ADMIN_USER}" -c "set -euo pipefail \
                && uv tool install conan \
                && uv tool install cmakelang \
            " \
    ; fi \
    && if [ -z "${NO_CROSS_DEV_TOOLS:-}" ]; then \
        pacman -S --noconfirm --needed avr-gcc mingw-w64-gcc \
    ; fi \
    && if [ -z "${NO_NEOVIM_CONFIG:-}" ]; then \
        neovim_config_git=https://github.com/nacitar/neovim-config.git \
        && su "${ADMIN_USER}" -c "set -euo pipefail \
                    && config_dir=\"\${HOME}/.config/nvim\" \
                    && git clone '${neovim_config_git}' \"\${config_dir}\" \
            " \
    ; fi \
    && if [ -z "${NO_YAY:-}" ]; then \
        pacman -S --noconfirm --needed base-devel \
        && yay_git=https://aur.archlinux.org/yay.git \
        && build_directory=/tmp/yay \
        && makepkg_temporary_sudoers='/etc/sudoers.d/wheel_pacman_nopasswd' \
        && echo '%wheel ALL=(ALL) NOPASSWD: /usr/sbin/pacman' \
            > "${makepkg_temporary_sudoers}" \
        && su "${ADMIN_USER}" -c "set -euo pipefail \
                    && git clone '${yay_git}' '${build_directory}' \
                    && cd '${build_directory}' \
                    && makepkg -si --noconfirm \
                    && cd - \
                    && rm -rf '${build_directory}' \
            " \
        && rm "${makepkg_temporary_sudoers}" \
        && su "${ADMIN_USER}" -c \
            'yay --sudoloop --save --version &>/dev/null' \
    ; fi \
    && pacman -Sc --noconfirm
# Don't run as root
USER ${ADMIN_USER}
WORKDIR /home/${ADMIN_USER}
