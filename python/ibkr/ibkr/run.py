import os
import sys
import traceback

import msgpackrpc
from msgpackrpc.compat import force_str
from msgpackrpc import error


def load_tws(tws_path: str) -> None:
    sys.path.append(os.path.join(tws_path, "source", "pythonclient"))


class Server(msgpackrpc.Server):
    def dispatch(self, method, param, responder):
        param = [p.decode() if isinstance(p, bytes) else p for p in param]
        try:
            method = force_str(method)
            if not hasattr(self._dispatcher, method):
                raise error.NoMethodError("'{0}' method not found".format(method))

            result = getattr(self._dispatcher, method)(*param)
            responder.set_result({"result": result, "error": None})
        except Exception as e:
            responder.set_result(
                {
                    "error": {
                        "type": type(e).__qualname__,
                        "message": str(e),
                        "stack": "".join(traceback.format_stack()),
                    },
                    "result": None,
                }
            )


if __name__ == "__main__":
    from ibkr import log

    log.install()

    tws_path = sys.argv[1]
    load_tws(tws_path)

    from ibkr import from_squid

    port = int(sys.argv[2])
    server = Server(from_squid.Dispatcher())
    server.listen(msgpackrpc.Address("localhost", port))
    server.start()
