import dataclasses
import logging
import time
import datetime
import multiprocessing as mp
import random
import queue
import typing

from ibapi import contract as ibcontract

from ibkr import to_ibapi, types

logger = logging.getLogger(__name__)


DEFAULT_WAIT = 10
START_TIMEOUT = 15
TIMEOUT_MUL = 1.5
DAY = 24 * 3600
TRIAL_LIMIT = 5


class Dispatcher:
    def __init__(self, wait: int = DEFAULT_WAIT):
        self._symbol_cache: dict[str, list[types.Contract]] = {}
        self._wait = wait
        self._last_request_timestamp: int = 0

    def search_symbol(
        self,
        symbol: str,
    ) -> list[types.Contract]:
        logger.debug(f"search_symbol({repr(symbol)})")
        if symbol in self._symbol_cache:
            res = self._symbol_cache[symbol]
        else:
            [results] = self._call_method(
                "reqMatchingSymbols",
                [symbol],
            )
            res: list[types.Contract] = [
                {
                    "id": c.conId,
                    "symbol": c.symbol,
                    "currency": c.currency,
                    "type": c.secType,
                    "exchange": c.primaryExchange,
                    "description": c.description,
                }
                for r in results
                if (c := r.contract)
            ]
            self._symbol_cache[symbol] = res
        logger.debug(f"search_symbol -> {len(res)} results")
        return res

    def fetch_contract_id(
        self,
        symbol: str,
        currency: str,
        type: str,
        exchange: str,
    ) -> int | None:
        logger.debug(
            f"fetch_contract_id({repr(symbol)}, {repr(currency)}, "
            f"{repr(type)}, {repr(exchange)})"
        )
        res = None
        for contract in self.search_symbol(symbol):
            if (
                contract["symbol"] == symbol
                and contract["currency"] == currency
                and contract["type"] == type
                and contract["exchange"] == exchange
            ):
                res = contract["id"]
                break
        logger.debug(f"fetch_contract_id -> {repr(res)}")
        return res

    def fetch_orders_from_day_by_minute(
        self,
        contract_id: int,
        to_timestamp: int,
        exchange: str,
    ) -> list[types.TimeStep]:
        logger.debug(
            f"fetch_orders_from_day_by_minute({contract_id}, {to_timestamp}, "
            f"{repr(exchange)})"
        )
        contract = ibcontract.Contract()
        contract.conId = contract_id
        contract.exchange = exchange
        bars = self._call_method(
            "reqHistoricalData",
            [
                contract,
                timestamp_to_ibkr(to_timestamp),
                "1 D",
                "1 min",
                "BID_ASK",
                1,
                2,
                False,
                [],
            ],
        )
        res: list[types.TimeStep] = [
            (
                int(bar.date),
                {
                    "bid_avg": bar.open,
                    "bid_min": bar.low,
                    "ask_avg": bar.close,
                    "ask_max": bar.high,
                },
            )
            for bar in bars
        ]
        logger.debug(f"fetch_orders_from_day_by_minute -> {len(res)} results")
        return res

    # TODO: cache
    def fetch_orders_by_minute(
        self,
        contract_id: int,
        from_timestamp: int,
        to_timestamp: int,
        exchange: str,
        increment: int = 6 * 3600,
        margin_future: int = DAY,
        margin_past: int = 4 * DAY,
    ) -> list[types.TimeStep]:
        """Weird and inefficient algorithm to overcome the unreasonableness of the IBKR API."""
        logger.debug(
            f"fetch_orders_by_minute({contract_id}, {from_timestamp}, {to_timestamp}, "
            f"{repr(exchange)})"
        )

        now_timestamp = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
        assert from_timestamp <= now_timestamp, (
            "fetch_orders_by_minute: requesting data from the future "
            f"({from_timestamp} > {now_timestamp})"
        )
        if to_timestamp > now_timestamp:
            logger.debug(
                f"fetch_orders_by_minute: lowering to_timestamp to {now_timestamp} (now)"
            )
            to_timestamp = now_timestamp

        @dataclasses.dataclass
        class Knowledge:
            bars_by_timestamp: dict[int, types.Bar] = dataclasses.field(
                default_factory=dict
            )
            from_timestamp: int = int(1e12)
            to_timestamp: int = 0

            @property
            def null(self) -> bool:
                assert bool(self.bars_by_timestamp) == (
                    self.from_timestamp <= self.to_timestamp
                )
                return not self.bars_by_timestamp

        def probe(probe_to_timestamp: int, knowledge: Knowledge) -> None:
            response_timesteps = self.fetch_orders_from_day_by_minute(
                contract_id,
                probe_to_timestamp,
                exchange=exchange,
            )

            for timestamp, bar in response_timesteps:
                knowledge.bars_by_timestamp[timestamp] = bar
                knowledge.from_timestamp = min(timestamp, knowledge.from_timestamp)
                knowledge.to_timestamp = max(timestamp, knowledge.to_timestamp)

        knowledge = Knowledge()

        probe_to_timestamp = to_timestamp
        while knowledge.null and probe_to_timestamp < to_timestamp + margin_future:
            probe(probe_to_timestamp, knowledge)
            probe_to_timestamp += increment

        probe_to_timestamp = to_timestamp - increment
        while knowledge.null and from_timestamp - margin_past < probe_to_timestamp:
            probe(probe_to_timestamp, knowledge)
            probe_to_timestamp -= increment

        if not knowledge.null:
            probe_to_timestamp = knowledge.from_timestamp
            while from_timestamp < knowledge.from_timestamp:
                probe(probe_to_timestamp, knowledge)
                probe_to_timestamp = min(
                    knowledge.from_timestamp, probe_to_timestamp - increment
                )

        logger.debug(
            "fetch_orders_by_minute: "
            f"got data from {knowledge.from_timestamp} to {knowledge.to_timestamp}"
        )

        timestamps_and_bars = [
            (timestamp, knowledge.bars_by_timestamp[timestamp])
            for timestamp in sorted(knowledge.bars_by_timestamp.keys())
        ]

        filled = []
        try:
            if not timestamps_and_bars:
                return []
            (last_timestamp, last_bar) = timestamps_and_bars[0]
            for timestamp, bar in timestamps_and_bars[1:]:
                while last_timestamp < timestamp:
                    filled.append((last_timestamp, last_bar))
                    last_timestamp += 60
                assert last_timestamp == timestamp
                last_bar = bar
            while last_timestamp < to_timestamp:
                filled.append((last_timestamp, last_bar))
                last_timestamp += 60
        finally:
            filtered = [
                (timestamp, bar)
                for (timestamp, bar) in filled
                if from_timestamp <= timestamp <= to_timestamp
            ]
            assert filtered, "fetch_orders_by_minute: no results"
            (first_timestamp, _) = filtered[0]
            assert from_timestamp <= first_timestamp < from_timestamp + 60, (
                "fetch_orders_by_minute: missing data "
                f"from {from_timestamp} to {first_timestamp}"
            )
            logger.debug(f"fetch_orders_by_minute -> {len(filtered)} results")
            return filtered

    def _call_method(
        self,
        method: str,
        args: list[typing.Any],
        timeout: float = START_TIMEOUT,
        n_trials_left: int = TRIAL_LIMIT,
        timeout_mul: float = TIMEOUT_MUL,
    ) -> typing.Any:
        now_timestamp = datetime.datetime.now(datetime.timezone.utc).timestamp()
        wait_time = self._wait - (now_timestamp - self._last_request_timestamp)
        if wait_time > 0:
            time.sleep(wait_time)
        self._last_request_timestamp = int(
            datetime.datetime.now(datetime.timezone.utc).timestamp()
        )

        response = mp.Queue()
        proc = mp.Process(target=target, args=(response, method, args))
        results = []
        try:
            proc.start()
            while True:
                result = response.get(timeout=timeout)
                if result is to_ibapi.EndOfResponse:
                    break
                results.append(result)
        except queue.Empty:
            if n_trials_left == 0:
                raise TimeoutError(
                    f"_call_method({repr(method)}: timeout; ran out of retries"
                )

            logger.debug(
                f"_call_method({repr(method)}): "
                f"timeout after {timeout}s; retrying with {timeout_mul}x more time"
            )
            return self._call_method(
                method,
                args,
                timeout=(timeout * timeout_mul),
                n_trials_left=(n_trials_left - 1),
            )
        finally:
            proc.terminate()
            proc.join(timeout=timeout)
        return results


def target(output: mp.Queue, method: str, args: list[typing.Any]) -> None:
    id = random.randrange(1000000)
    ibkr_client = to_ibapi.Client("127.0.0.1", 4002, id, output)
    getattr(ibkr_client, method)(0, *args)
    ibkr_client.run()


def timestamp_to_ibkr(timestamp: int) -> str:
    return datetime.datetime.fromtimestamp(timestamp).strftime("%Y%m%d-%H:%M:00")
