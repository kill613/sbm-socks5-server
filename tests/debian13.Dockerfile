FROM debian:13
ENV container=docker
RUN set -eu; \
    for mirror in mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn deb.debian.org; do \
      printf 'deb http://%s/debian trixie main\n' "$mirror" >/tmp/tuna.list; \
      if apt-get -o Dir::Etc::sourcelist=/tmp/tuna.list -o Dir::Etc::sourceparts=- -o Acquire::http::Timeout=20 -o Acquire::Retries=1 -o APT::Update::Error-Mode=any update \
        && DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Etc::sourcelist=/tmp/tuna.list -o Dir::Etc::sourceparts=- -o Acquire::http::Timeout=20 -o Acquire::Retries=1 install -y systemd systemd-sysv dbus iproute2 ca-certificates; then \
          rm /tmp/tuna.list; exit 0; \
      fi; \
    done; exit 1
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
