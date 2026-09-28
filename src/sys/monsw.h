/*
 * sys/monsw.h -- the monitor switch: /dev/monsw and its kernel API (P-8, 2026-09-28).
 *
 * One machine resource, the CIA-B line(s) that flip a monitor or KVM between the native
 * video and an RTG card, owned by one card-independent driver (src/monsw.c) instead of by
 * each card driver.  Installed as /usr/include/sys/monsw.h on images and in the Model-B
 * sysroot; usable from K&R and ANSI C, kernel and user.
 *
 * The configuration value has the Z3660 firmware's `monitor_switch` meanings, so a box
 * behaves alike under AmigaOS P96 and Amix:
 *
 *   MONSW_CTS    1   drive CIA-B PRA bit 4 (CTS)
 *   MONSW_SEL    2   drive CIA-B PRA bit 2 (SEL)
 *   MONSW_CTSLVL 16  CTS level flag: RTG is the bit CLEAR (without it, RTG is the bit set)
 *   MONSW_SELLVL 32  SEL level flag, likewise
 *
 * Any other bit makes the value invalid (it is reported once and taken as 0).  0 = never
 * touch a line.  Where the value comes from, later wins:
 *   seed     a registered card driver's value at attach (the Z3660's register 0x318),
 *            taken only from the first card that offers one
 *   SETCFG   MONSWIOC_SETCFG, root only: /etc/monsw written in at boot by an rc step
 *   patched  monsw_config in the kernel image, -1 = unset; set, it forces the value and
 *            SETCFG answers EBUSY
 *
 * User side: open /dev/monsw; MONSWIOC_RTG / MONSWIOC_NATIVE switch; the switch goes back
 * to native on the device's last close, so a holder that dies cannot leave it on RTG.
 * The X servers do not use this device: they ask their own RTG device
 * (SVGAIOCSetMonitorSwitch), and a line-switched card's driver calls monsw_set().
 */
#ifndef _SYS_MONSW_H
#define _SYS_MONSW_H

#define MONSW_CTS       0x01
#define MONSW_SEL       0x02
#define MONSW_CTSLVL    0x10
#define MONSW_SELLVL    0x20
#define MONSW_VALID     (MONSW_CTS | MONSW_SEL | MONSW_CTSLVL | MONSW_SELLVL)

#define MONSWIOC        ('M' << 8)
#define MONSWIOC_RTG    (MONSWIOC | 1)  /* switch to the RTG card; arg unused */
#define MONSWIOC_NATIVE (MONSWIOC | 2)  /* switch to native video; arg unused */
#define MONSWIOC_GETCFG (MONSWIOC | 3)  /* arg: struct monsw_info * */
#define MONSWIOC_SETCFG (MONSWIOC | 4)  /* arg: the value itself, -1 = unset; root only */

/* mi_source */
#define MONSW_SRC_NONE  0
#define MONSW_SRC_SEED  1
#define MONSW_SRC_SET   2
#define MONSW_SRC_PATCH 3

struct monsw_info {
	int mi_config;  /* the value in effect */
	int mi_source;  /* MONSW_SRC_*: where it came from */
	int mi_state;   /* last requested state: 1 RTG, 0 native, -1 none since boot */
	int mi_holder;  /* 1 while a /dev/monsw holder has asked for RTG */
	int mi_ncards;  /* card drivers registered */
};

#ifdef _KERNEL
extern int monsw_config;        /* patchable; -1 = unset */
#if defined(__STDC__)
extern void monsw_set(int);
extern int monsw_register(char *, int);
extern void monsw_unregister(int);
extern void monsw_lastclose(int);
#else
extern void monsw_set();        /* (rtg): 1 RTG, 0 native; acts only on a change */
extern int monsw_register();    /* (name, seed): a handle, or -1; seed -1 = none */
extern void monsw_unregister(); /* (handle) */
extern void monsw_lastclose();  /* (handle): native unless a /dev/monsw holder wants RTG */
#endif
#endif /* _KERNEL */

#endif /* _SYS_MONSW_H */
