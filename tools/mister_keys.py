#!/usr/bin/env python3
# Virtual keyboard for the MiSTer (Linux uinput, legacy API, no evdev
# module needed). Usage: mister_keys.py <key>[:<hold_s>] ... e.g.
#   mister_keys.py 5 1 up:1.0 lctrl
# Keys: 0-9, f1-f12, up down left right, lctrl lalt space lshift, a-z.
# Each key is pressed, held (default 0.15 s), released, then 0.3 s pause.
# 'a+b' presses them together as a chord (Alt+F1 for a savestate save).
import fcntl, os, struct, sys, time

KEYS = {'1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,'0':11,
        'q':16,'w':17,'e':18,'r':19,'t':20,'y':21,'u':22,'i':23,'o':24,'p':25,
        'a':30,'s':31,'d':32,'f':33,'g':34,'h':35,'j':36,'k':37,'l':38,
        'z':44,'x':45,'c':46,'v':47,'b':48,'n':49,'m':50,
        'lctrl':29,'lshift':42,'lalt':56,'space':57,'enter':28,'esc':1,
        'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,'f7':65,'f8':66,'f9':67,'f10':68,'f11':87,'f12':88,
        'up':103,'left':105,'right':106,'down':108}

UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for code in KEYS.values():
    fcntl.ioctl(fd, UI_SET_KEYBIT, code)
# struct uinput_user_dev: name[80], input_id (4 x u16), ff_effects_max u32, 4 x absXXX[64] s32
dev = struct.pack('80sHHHHI', b'MiSTer test keyboard', 0x03, 0x1234, 0x5678, 1, 0) + b'\0' * (4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.0)  # let MiSTer's input scan pick the device up

def ev(t, c, v):
    now = time.time(); sec = int(now); usec = int((now - sec) * 1e6)
    os.write(fd, struct.pack('llHHi', sec, usec, t, c, v))

# 'a+b' is a CHORD: every key down, held together, then up in reverse order.
# Savestates need it -- Alt+F1 saves and F1 alone loads, so pressing the two in
# sequence is a different command. The default 0.15 s hold is also too short for
# a savestate: the first attempts looked like "load does nothing" until the hold
# went up to 0.6 s (docs/hw-bringup.md, 2026-09-20).
for arg in sys.argv[1:]:
    combo, _, hold = arg.partition(':')
    codes = [KEYS[n.lower()] for n in combo.split('+')]
    hold = float(hold) if hold else 0.15
    for c in codes:
        ev(EV_KEY, c, 1); ev(EV_SYN, 0, 0); time.sleep(0.03)
    time.sleep(hold)
    for c in reversed(codes):
        ev(EV_KEY, c, 0); ev(EV_SYN, 0, 0); time.sleep(0.03)
    time.sleep(0.3)

time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
