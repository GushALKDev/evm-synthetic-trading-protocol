// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title LocalChainlinkFeed
 * @author GushALKDev
 * @notice Local-only stand-in for a Chainlink aggregator, with round history, for the anvil rehearsal of the demo
 *         (app/scripts/local-chain.sh). It is never deployed to Base Sepolia, where the app reads the real feeds.
 * @dev Anyone can set the answer: on the local chain, the scripts and the app's tests move prices with it. It checks
 *      nothing beyond the order of seeded round times. Round ids count up from 1 in a single phase, and getRoundData reverts for an id with no round, as a
 *      Chainlink aggregator does, so the app's end of history path runs locally too.
 */
contract LocalChainlinkFeed {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct Round {
        int192 answer; //    24 bytes -┐  Slot 0 (full)
        uint64 updatedAt; //  8 bytes -┘
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint8 public immutable decimals;

    /// @dev Round id i + 1 is stored at index i
    Round[] private _rounds;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoDataPresent(uint80 roundId);
    error HistoryAlreadySeeded(uint256 rounds);
    error LengthMismatch(uint256 answers, uint256 times);
    error RoundTimeOutOfOrder(uint256 index, uint256 time);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Publishes a new round with the answer, stamped at the current block
     */
    function setAnswer(int256 _answer) external {
        // forge-lint: disable-next-line(unsafe-typecast) safe: local prices are far inside int192
        _rounds.push(Round({answer: int192(_answer), updatedAt: uint64(block.timestamp)}));
    }

    /**
     * @notice Moves the latest round's timestamp, so a test can make the feed look stale or fresh
     */
    function setUpdatedAt(uint256 _updatedAt) external {
        // forge-lint: disable-next-line(unsafe-typecast) safe: timestamps fit uint64
        _rounds[_rounds.length - 1].updatedAt = uint64(_updatedAt);
    }

    /**
     * @notice Writes _count past rounds, _interval seconds apart and ending one interval before now, as a deterministic
     *         random walk of at most _maxStepBps per round that arrives at _end. Then setAnswer(_end) publishes the
     *         current round. Only on an empty feed, so round times stay in order.
     */
    function seedHistory(int256 _end, uint256 _count, uint256 _interval, uint256 _maxStepBps) external {
        if (_rounds.length != 0) revert HistoryAlreadySeeded(_rounds.length);
        int256[] memory answers = new int256[](_count);
        int256 price = _end;
        // Walk backwards from the end, so the history joins the current answer without a jump
        for (uint256 i = _count; i > 0; --i) {
            uint256 seed = uint256(keccak256(abi.encode(address(this), i)));
            // forge-lint: disable-next-line(unsafe-typecast) safe: at most _maxStepBps, a few dozen
            int256 step = int256(seed % (_maxStepBps + 1));
            price = seed & (1 << 128) == 0 ? (price * (10_000 + step)) / 10_000 : (price * (10_000 - step)) / 10_000;
            answers[i - 1] = price;
        }
        for (uint256 i; i < _count; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) safe: local prices are far inside int192, timestamps fit uint64
            _rounds.push(Round({answer: int192(answers[i]), updatedAt: uint64(block.timestamp - (_count - i) * _interval)}));
        }
    }

    /**
     * @notice Writes past rounds as given, so the local history can follow recorded market prices. Times must rise and
     *         stay before the current block. Only on an empty feed, like seedHistory.
     */
    function seedRounds(int256[] calldata _answers, uint256[] calldata _times) external {
        if (_rounds.length != 0) revert HistoryAlreadySeeded(_rounds.length);
        if (_answers.length != _times.length) revert LengthMismatch(_answers.length, _times.length);
        uint256 previous;
        for (uint256 i; i < _answers.length; ++i) {
            if (_times[i] <= previous || _times[i] >= block.timestamp) revert RoundTimeOutOfOrder(i, _times[i]);
            previous = _times[i];
            // forge-lint: disable-next-line(unsafe-typecast) safe: local prices are far inside int192, timestamps fit uint64
            _rounds.push(Round({answer: int192(_answers[i]), updatedAt: uint64(_times[i])}));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            AGGREGATOR API
    //////////////////////////////////////////////////////////////*/

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        // forge-lint: disable-next-line(unsafe-typecast) safe: a local feed holds far fewer than 2^80 rounds
        return getRoundData(uint80(_rounds.length));
    }

    function getRoundData(uint80 _roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (_roundId == 0 || _roundId > _rounds.length) revert NoDataPresent(_roundId);
        Round memory round = _rounds[_roundId - 1];
        return (_roundId, round.answer, round.updatedAt, round.updatedAt, _roundId);
    }
}
