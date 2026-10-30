"""3proxy1.0.2的严格中继端口范围修正，保留上游协议与认证实现。

Linux IP_LOCAL_PORT_RANGE只收窄系统临时端口范围：如果指定范围在其
外部，内核会忽略边界。云安全组需要确定端口，故使用上游已有的显式
bind回退实现，并在端口范围耗尽时失败，禁止逃逸到随机临时端口。
"""
from pathlib import Path

KERNEL_RANGE = '''#ifdef IP_LOCAL_PORT_RANGE
	if(*SAFAMILY(sa) == AF_INET &&
	   !param->srv->so._setsockopt(param->sostate, sock, IPPROTO_IP, IP_LOCAL_PORT_RANGE,
		(char *)&range, sizeof(range))){
		*SAPORT(sa) = 0;
		return param->srv->so._bind(param->sostate, sock, (struct sockaddr *)sa, SASIZE(sa));
	}
#endif'''
ESCAPE_RANGE = '''	/* Every port tried was taken. Fall back to an ephemeral one, which is
	   what the kernel option above does when it cannot honour the range, so
	   an exhausted range behaves the same way on every platform. */
	*SAPORT(sa) = 0;
	return param->srv->so._bind(param->sostate, sock, (struct sockaddr *)sa, SASIZE(sa));'''


def apply(source):
    path = Path(source) / 'src/common.c'
    text = path.read_text(encoding='utf-8')
    if text.count(KERNEL_RANGE) != 1 or text.count(ESCAPE_RANGE) != 1:
        raise ValueError('上游固定版本的端口范围代码不匹配，拒绝盲目打补丁')
    text = text.replace(KERNEL_RANGE, '/* SBM: explicit bind enforces the configured relay range. */')
    text = text.replace(ESCAPE_RANGE, '\t/* SBM: never escape the configured relay range. */\n\terrno = EADDRINUSE;\n\treturn -1;')
    path.write_text(text, encoding='utf-8')
