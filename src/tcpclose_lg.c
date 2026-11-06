/*
 * tcpclose_lg.c -- a TCP close sends what was written before the FIN, as a close under SO_LINGER does.
 *
 * THE BUG.  TCP's unsent data is its stream's own write queue, counted in the tcpcb's t_qsize, and the queue is
 * freed when the close returns.  The stock tcpclose keeps the data only under SO_LINGER with a time: it starts the
 * linger timer and sleeps until the FIN is acknowledged or the timer runs out.  Without SO_LINGER it clears t_qsize
 * and returns at once, and the FIN follows what TCP had already sent: the peer reads an orderly end after a prefix.
 * Seen as in.ftpd's passive downloads cut short (its active path sets SO_LINGER, its passive path does not).  The
 * stream head never drains a socket either: libsocket sets its close time to 0.
 *
 * THE FIX.  tcpclose_lg takes tcpclose's place as the close of TCP's upper read queue (the only one STREAMS calls;
 * the retarget is made after the link).  When the endpoint has no SO_LINGER it gets SO_LINGER with TCP_CLOSE_LINGER
 * seconds, then the stock tcpclose runs: with nothing unsent it returns at once as before; with data unsent it waits
 * until the data and the FIN are acknowledged, the peer resets, or TCP_CLOSE_LINGER runs out (the data is then
 * dropped, as stock).  A signal ends the wait as it ends any linger.  A nonzero linger keeps tcp_disconnect's
 * orderly path; SO_LINGER with 0 seconds (an abortive close, a reset) and SO_LINGER with a time are the user's own
 * and are left alone.  The cost: such a close blocks until the peer has acknowledged the tail, where stock returned
 * at once having dropped it.
 *
 * MIT licence, see LICENSE in kernel/k30.
 */
#define STRNET
#include <sys/types.h>
#include <sys/stream.h>
#include <sys/socket.h>
#include <netinet/in.h>
#undef _KERNEL		/* route.h's kernel part defines the routing tables (commons): only struct route is wanted */
#include <net/route.h>
#define _KERNEL
#include <netinet/in_pcb.h>

#define TCP_CLOSE_LINGER 60	/* seconds; in.ftpd's active path asks for the same */

extern int tcpclose();

long tcl_magic = 0x54434c21;	/* "TCL!" */
long tcl_calls = 0;		/* every close of a TCP stream */
long tcl_set = 0;		/* given SO_LINGER here */

int
tcpclose_lg(q, flag, credp)
	queue_t *q;
	int flag;
	caddr_t credp;
{
	struct inpcb *inp = qtoinp(q);

	tcl_calls++;
	if (inp != 0 && !(inp->inp_protoopt & SO_LINGER)) {
		inp->inp_protoopt |= SO_LINGER;
		inp->inp_linger = TCP_CLOSE_LINGER;
		tcl_set++;
	}
	return tcpclose(q, flag, credp);
}
