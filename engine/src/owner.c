// Which process holds a socket on a given local port. macOS keeps no port -> process table, so this
// walks each process's file descriptors through libproc (root sees every process).
#include <libproc.h>
#include <sys/proc_info.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>

// has_port reports whether pid holds a TCP (tcp != 0) or UDP socket on local port lport.
int netfuse_has_port(int pid, int tcp, int lport) {
	int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
	if (n <= 0) return 0;
	n += 32 * sizeof(struct proc_fdinfo); // room for fds opened in between
	struct proc_fdinfo *fds = malloc(n);
	if (!fds) return 0;
	n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, n);
	int found = 0;
	for (int i = 0; i < n / (int)sizeof(struct proc_fdinfo) && !found; i++) {
		if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
		struct socket_fdinfo si;
		if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != sizeof si) continue;
		if (si.psi.soi_family != AF_INET && si.psi.soi_family != AF_INET6) continue;
		int p;
		if (tcp) {
			if (si.psi.soi_kind != SOCKINFO_TCP) continue;
			p = si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport;
		} else {
			if (si.psi.soi_kind != SOCKINFO_IN || si.psi.soi_protocol != IPPROTO_UDP) continue;
			p = si.psi.soi_proto.pri_in.insi_lport;
		}
		found = ntohs((uint16_t)p) == lport;
	}
	free(fds);
	return found;
}

// find_pid scans every process except self and returns the one holding the port, or 0.
int netfuse_find_pid(int tcp, int lport, int self) {
	int n = proc_listallpids(NULL, 0);
	if (n <= 0) return 0;
	n += 64;
	int *pids = malloc(n * sizeof(int));
	if (!pids) return 0;
	n = proc_listallpids(pids, n * sizeof(int));
	int found = 0;
	for (int i = 0; i < n && !found; i++) {
		if (pids[i] > 0 && pids[i] != self && netfuse_has_port(pids[i], tcp, lport)) found = pids[i];
	}
	free(pids);
	return found;
}

int netfuse_pid_path(int pid, char *buf, int size) { return proc_pidpath(pid, buf, size); }
