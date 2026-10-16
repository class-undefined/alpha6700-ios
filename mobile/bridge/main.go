package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"github.com/class-undefined/alpha6700-ios/mobile/core"
	"sync"
	"unsafe"
)

var registry = struct {
	sync.Mutex
	next    int64
	engines map[int64]*core.Engine
}{engines: map[int64]*core.Engine{}}

func engine(id C.int64_t) *core.Engine {
	registry.Lock()
	defer registry.Unlock()
	return registry.engines[int64(id)]
}

//export CameraCreate
func CameraCreate(root, guid *C.char) C.int64_t {
	e, err := core.New(C.GoString(root), C.GoString(guid))
	if err != nil {
		return 0
	}
	registry.Lock()
	defer registry.Unlock()
	registry.next++
	registry.engines[registry.next] = e
	return C.int64_t(registry.next)
}

//export CameraRequest
func CameraRequest(id C.int64_t, request *C.char) *C.char {
	e := engine(id)
	if e == nil {
		return C.CString(`{"ok":false,"error":"Invalid engine"}`)
	}
	return C.CString(e.Request(C.GoString(request)))
}

//export CameraCopyFrame
func CameraCopyFrame(id C.int64_t, length *C.int64_t) unsafe.Pointer {
	*length = 0
	e := engine(id)
	if e == nil {
		return nil
	}
	b := e.Frame()
	if len(b) == 0 {
		return nil
	}
	*length = C.int64_t(len(b))
	return C.CBytes(b)
}

//export CameraAbort
func CameraAbort(id C.int64_t) {
	if e := engine(id); e != nil {
		e.Abort()
	}
}

//export CameraDestroy
func CameraDestroy(id C.int64_t) {
	registry.Lock()
	e := registry.engines[int64(id)]
	delete(registry.engines, int64(id))
	registry.Unlock()
	if e != nil {
		e.Abort()
		e.Request(`{"op":"disconnect"}`)
	}
}

//export CameraFree
func CameraFree(p unsafe.Pointer) { C.free(p) }
func main()                       {}
