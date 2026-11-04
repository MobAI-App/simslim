package simslim

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// watchDeviceDirs calls created for each directory that appears in one of
// setDirs, until ctx is cancelled. A kqueue NOTE_WRITE on each set directory
// wakes it within a millisecond of `simctl create`, and costs nothing while
// idle. A set directory that does not exist yet (XCTestDevices before the first
// parallel-testing run) is attached again every retry; its devices count as new
// from then on. A deleted device directory is forgotten, so known holds only
// the devices that exist.
func watchDeviceDirs(ctx context.Context, setDirs map[string]string, retry time.Duration, created func(deviceDir)) {
	kq, err := syscall.Kqueue()
	if err != nil {
		return // the scan still catches every device, only later
	}
	defer syscall.Close(kq)
	// An EVFILT_USER event wakes the blocked kevent when ctx is cancelled.
	wake := []syscall.Kevent_t{{Ident: 0, Filter: syscall.EVFILT_USER, Flags: syscall.EV_ADD | syscall.EV_CLEAR}}
	if _, err := syscall.Kevent(kq, wake, nil, nil); err != nil {
		return
	}
	woken := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		trigger := []syscall.Kevent_t{{Ident: 0, Filter: syscall.EVFILT_USER, Fflags: syscall.NOTE_TRIGGER}}
		syscall.Kevent(kq, trigger, nil, nil)
		close(woken)
	})
	defer func() {
		if !stop() {
			<-woken // kq stays open until the trigger is done with it
		}
	}()

	fds := map[string]int{}               // attached set directory -> its fd
	dirs := map[uint64]string{}           // fd -> attached set directory
	known := map[string]map[string]bool{} // set directory -> its device directories
	defer func() {
		for _, fd := range fds {
			syscall.Close(fd)
		}
	}()
	// list records dir's device directories, reporting the new ones unless this
	// is the baseline taken at startup: those are the first scan's business.
	list := func(dir string, report bool) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		was := known[dir]
		now := map[string]bool{}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			now[e.Name()] = true
			if report && !was[e.Name()] {
				created(deviceDir{path: filepath.Join(dir, e.Name()), set: setDirs[dir]})
			}
		}
		known[dir] = now
	}
	attach := func(report bool) {
		for dir := range setDirs {
			if _, ok := fds[dir]; ok {
				continue
			}
			fd, err := syscall.Open(dir, syscall.O_EVTONLY|syscall.O_DIRECTORY, 0)
			if err != nil {
				continue
			}
			ev := []syscall.Kevent_t{{Ident: uint64(fd), Filter: syscall.EVFILT_VNODE, Flags: syscall.EV_ADD | syscall.EV_CLEAR, Fflags: syscall.NOTE_WRITE | syscall.NOTE_DELETE | syscall.NOTE_RENAME}}
			if _, err := syscall.Kevent(kq, ev, nil, nil); err != nil {
				syscall.Close(fd)
				continue
			}
			fds[dir] = fd
			dirs[uint64(fd)] = dir
			list(dir, report)
		}
	}
	attach(false)
	timeout := syscall.NsecToTimespec(retry.Nanoseconds())
	events := make([]syscall.Kevent_t, len(setDirs)+1)
	for ctx.Err() == nil {
		n, err := syscall.Kevent(kq, nil, events, &timeout)
		if err != nil && err != syscall.EINTR {
			return
		}
		for _, ev := range events[:max(n, 0)] {
			dir, ok := dirs[ev.Ident]
			if ev.Filter != syscall.EVFILT_VNODE || !ok {
				continue
			}
			if ev.Fflags&(syscall.NOTE_DELETE|syscall.NOTE_RENAME) != 0 {
				// The set directory itself went away; attach it again once
				// it is back, and report what it holds then.
				syscall.Close(fds[dir])
				delete(fds, dir)
				delete(dirs, ev.Ident)
				delete(known, dir)
				continue
			}
			list(dir, true)
		}
		attach(true)
	}
}
