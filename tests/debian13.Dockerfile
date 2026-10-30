FROM debian:13
ENV container=docker
RUN printf 'deb http://mirrors.tuna.tsinghua.edu.cn/debian trixie main\n' >/tmp/tuna.list \
    && apt-get -o Dir::Etc::sourcelist=/tmp/tuna.list -o Dir::Etc::sourceparts=- update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Etc::sourcelist=/tmp/tuna.list -o Dir::Etc::sourceparts=- install -y systemd systemd-sysv dbus iproute2 ca-certificates \
    && rm /tmp/tuna.list
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
