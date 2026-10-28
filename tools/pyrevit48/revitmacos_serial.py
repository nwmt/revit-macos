# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT
# revit-macos: one Revit request at a time for pyRevit 4.8's Routes server (pyrevit/routes/server/server.py).
# pyRevit 4.8 serves each HTTP request on its own thread but has one shared REQUEST_HNDLR and one ExternalEvent for
# all of them: two requests at once can swap each other's request and answer. The patched server.py hands its
# Revit-context branch to dispatch() here, which holds a lock from preparing the shared handler until the answer is
# written. A request with a callbackUrl is refused before it touches anything: pyRevit would answer it at once and
# run it later, outside the lock. Runs on IronPython 2.7.7 (no Lock.acquire timeout there, hence the polling) and on
# CPython 3 (tests/test_pyrevit48_routes.py). Imports nothing from pyRevit: the handler builds the responses.
import threading
import time

VERSION = 1
_LOCK = threading.Lock()


def dispatch(handler, request, route_handler, timeout=60, clock=time.time, sleep=time.sleep):
    """Run one Revit-context request through handler (pyRevit's HttpRequestHandler) and write its answer."""
    if getattr(request, "callback_url", None):
        return handler._write_response(handler.make_response(400, {"error": "Callbacks are not supported."}))
    deadline = clock() + timeout
    while not _LOCK.acquire(False):
        if clock() >= deadline:
            return handler._write_response(handler.make_response(503, {"error": "Revit is busy with another request"}))
        sleep(0.05)
    try:
        req_hndlr, event_hndlr = handler._prepare_host_handler(request, route_handler)
        handler._call_host_event_sync(req_hndlr, event_hndlr)
        handler._write_response(req_hndlr.response)
    finally:
        _LOCK.release()
