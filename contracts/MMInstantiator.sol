// Copyright (C) 2020 Cartesi Pte. Ltd.

// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.

// This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Note: This component currently has dependencies that are licensed under the GNU
// GPL, version 3, and so you should treat this component as a whole as being under
// the GPL version 3. But all Cartesi-written code in this component is licensed
// under the Apache License, version 2, or a compatible permissive license, and can
// be used independently under the Apache v2 license. After this component is
// rewritten, the entire component will be released under the Apache v2 license.


/// @title An instantiator of memory managers
pragma solidity ^0.5.0;

import "@cartesi/util/contracts/Decorated.sol";
import "./MMInterface.sol";
import "@cartesi/util/contracts/Merkle.sol";


contract MMInstantiator is MMInterface, Decorated {
  // the provider will fill the memory for the client to read and write
  // memory starts with hash and all values that are inserted are first verified
  // then client can read inserted values and write some more
  // finally the provider has to update the hash to account for writes

    struct ReadWrite {
        bool wasRead;
        uint64 position;
        bytes8 value;
    }

    // IMPLEMENT GARBAGE COLLECTOR AFTER AN INSTACE IS FINISHED!
    struct MMCtx {
        address provider;
        address client;
        bytes32 initialHash;
        bytes32 newHash; // hash after some write operations have been proved
        ReadWrite[] history;
        uint historyPointer;
        state currentState;
    }

    mapping(uint256 => MMCtx) internal instance;

    // These are the possible states and transitions of the contract.
    //
    // +---+
    // |   |
    // +---+
    //   |
    //   | instantiate
    //   v
    // +---------------+    | proveRead
    // | WaitingProofs |----| proveWrite
    // +---------------+
    //   |
    //   | finishProofPhase
    //   v
    // +----------------+    |read
    // | WaitingReplay  |----|write
    // +----------------+
    //   |
    //   | finishReplayPhase
    //   v
    // +----------------+
    // | FinishedReplay |
    // +----------------+
    //

    event MemoryCreated(uint256 _index, bytes32 _initialHash);
    event ValueProved(uint256 _index, bool _wasRead, uint64 _position, bytes8 _value);
    event ValueRead(uint256 _index, uint64 _position, bytes8 _value);
    event ValueWritten(uint256 _index, uint64 _position, bytes8 _value);
    event FinishedProofs(uint256 _index);
    event FinishedReplay(uint256 _index);

    function instantiate(address _provider, address _client, bytes32 _initialHash) public returns (uint256) {
        require(_provider != _client, "Provider and client need to differ");
        MMCtx storage currentInstance = instance[currentIndex];
        currentInstance.provider = _provider;
        currentInstance.client = _client;
        currentInstance.initialHash = _initialHash;
        currentInstance.newHash = _initialHash;
        currentInstance.historyPointer = 0;
        currentInstance.currentState = state.WaitingProofs;
        emit MemoryCreated(currentIndex, _initialHash);

        active[currentIndex] = true;
        return currentIndex++;
    }

    /// @notice Proves that a certain value in current memory is correct
    // @param _position The address of the value to be confirmed
    // @param _value The value in that address to be confirmed
    // @param proof The proof that this value is correct
    function proveRead(
        uint256 _index,
        uint64 _position,
        bytes8 _value,
        bytes32[] memory proof) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].provider)
        increasesNonce(_index)
    {
        require(instance[_index].currentState == state.WaitingProofs, "CurrentState is not WaitingProofs, cannot proveRead");
        require(Merkle.getRoot(_position, _value, proof) == instance[_index].newHash, "Merkle proof does not match");
        instance[_index].history.push(ReadWrite(true, _position, _value));
        emit ValueProved(
            _index,
            true,
            _position,
            _value
        );
    }

    /// @notice Register a write operation and update newHash
    /// @param _position to be written
    /// @param _oldValue before write
    /// @param _newValue to be written
    /// @param proof The proof that the old value was correct
    function proveWrite(
        uint256 _index,
        uint64 _position,
        bytes8 _oldValue,
        bytes8 _newValue,
        bytes32[] memory proof) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].provider)
        increasesNonce(_index)
    {
        require(instance[_index].currentState == state.WaitingProofs, "CurrentState is not WaitingProofs, cannot proveWrite");
        // check proof of old value
        require(Merkle.getRoot(_position, _oldValue, proof) == instance[_index].newHash, "Merkle proof of write does not match");
        // update root
        instance[_index].newHash = Merkle.getRoot(_position, _newValue, proof);
        instance[_index].history.push(ReadWrite(false, _position, _newValue));
        emit ValueProved(
            _index,
            false,
            _position,
            _newValue
        );
    }

    /// @notice Stop memory insertion and start read and write phase
    function finishProofPhase(uint256 _index) public
        onlyInstantiated(_index)
        onlyBy(instance[_index].provider)
        increasesNonce(_index)
    {
        require(instance[_index].currentState == state.WaitingProofs, "CurrentState is not WaitingProofs, cannot finishProofPhase");
        instance[_index].currentState = state.WaitingReplay;
        emit FinishedProofs(_index);
    }

    /// @notice Replays a read in memory that has been proved to be correct
    /// according to initial hash
    /// @param _position of the desired memory
    function read(uint256 _index, uint64 _position) public
        onlyInstantiated(_index)
        increasesNonce(_index)
        returns (bytes8)
    {
        require(instance[_index].client == tx.origin, "Transaction has to be originated by the client");
        require(instance[_index].currentState == state.WaitingReplay, "CurrentState is not WaitingReplay, cannot read");
        require((_position & 7) == 0, "Position is not aligned");
        uint pointer = instance[_index].historyPointer;
        ReadWrite storage  pointInHistory = instance[_index].history[pointer];
        require(pointInHistory.wasRead, "PointInHistory has not been read");
        require(pointInHistory.position == _position, "PointInHistory's position does not match");
        bytes8 value = pointInHistory.value;
        delete(instance[_index].history[pointer]);
        instance[_index].historyPointer++;
        emit ValueRead(_index, _position, value);
        return value;
    }

    /// @notice Replays a write in memory that was proved correct
    /// @param _position of the write
    /// @param _value to be written
    function write(uint256 _index, uint64 _position, bytes8 _value) public
        onlyInstantiated(_index)
        increasesNonce(_index)
    {
        require(instance[_index].client == tx.origin, "Transaction has to be originated by the client");
        require(instance[_index].currentState == state.WaitingReplay, "CurrentState is not WaitingReplay, cannot write");
        require((_position & 7) == 0, "Position is not aligned");
        uint pointer = instance[_index].historyPointer;
        ReadWrite storage pointInHistory = instance[_index].history[pointer];
        require(!pointInHistory.wasRead, "PointInHistory was not write");
        require(pointInHistory.position == _position, "PointInHistory's position does not match");
        require(pointInHistory.value == _value, "PointInHistory's value does not match");
        delete(instance[_index].history[pointer]);
        instance[_index].historyPointer++;
        emit ValueWritten(_index, _position, _value);
    }

    /// @notice Stop write (or read) phase
    function finishReplayPhase(uint256 _index) public
        onlyInstantiated(_index)
        increasesNonce(_index)
    {
        require(instance[_index].client == tx.origin, "Transaction has to be originated by the client");
        require(instance[_index].currentState == state.WaitingReplay, "CurrentState is not WaitingReplay, cannot finishReplayPhase");
        require(instance[_index].historyPointer == instance[_index].history.length, "History pointer does not match length");
        delete(instance[_index].history);
        delete(instance[_index].historyPointer);
        instance[_index].currentState = state.FinishedReplay;

        deactivate(_index);
        emit FinishedReplay(_index);
    }

    // getter methods
    function isConcerned(uint256 _index, address _user) public view returns (bool) {
        return ((instance[_index].provider == _user) || (instance[_index].client == _user));
    }

    function getState(uint256 _index, address) public view
        onlyInstantiated(_index)
        returns (address _provider,
                address _client,
                bytes32 _initialHash,
                bytes32 _newHash,
                uint _numberSubmitted,
                bytes32 _currentState)
    {
        MMCtx memory i = instance[_index];

        return (
            i.provider,
            i.client,
            i.initialHash,
            i.newHash,
            i.history.length,
            getCurrentState(_index)
        );
    }

    function getSubInstances(uint256, address)
        public view returns (address[] memory, uint256[] memory)
    {
        address[] memory a = new address[](0);
        uint256[] memory i = new uint256[](0);
        return (a, i);
    }

    function provider(uint256 _index) public view
        onlyInstantiated(_index)
        returns (address)
    { return instance[_index].provider; }

    function client(uint256 _index) public view
        onlyInstantiated(_index)
        returns (address)
    { return instance[_index].client; }

    function initialHash(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bytes32)
    { return instance[_index].initialHash; }

    function newHash(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bytes32)
    { return instance[_index].newHash; }

    // state getters

    function getCurrentState(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bytes32)
    {
        if (instance[_index].currentState == state.WaitingProofs) {
            return "WaitingProofs";
        }
        if (instance[_index].currentState == state.WaitingReplay) {
            return "WaitingReplay";
        }
        if (instance[_index].currentState == state.FinishedReplay) {
            return "FinishedReplay";
        }
        require(false, "Unrecognized state");
    }

    /// @notice Get the worst case scenario duration for a specific state
    /// @param _roundDuration security parameter, the max time an agent
    //          has to react and submit one simple transaction
    /// @param _timeToStartMachine time to build the machine for the first time
    function getMaxStateDuration(
        state _state,
        uint256 _roundDuration,
        uint256 _timeToStartMachine) private view returns (uint256)
    {
        if (_state == state.WaitingProofs) {
            // proving siblings is assumed to be free
            // so its time to start the machine 
            // + one round duration to send the proofs
            // + one transaction for finishProofPhase transaction
            return _timeToStartMachine + uint256(2) * _roundDuration;
        }
        if (_state == state.WaitingReplay) {
            // one transaction for the step function to be completed
            return _roundDuration;
        }
        if (_state == state.FinishedReplay) {
            // one transaction for finishReplay transaction
            return _roundDuration;
        }

        require(false, "Unrecognized state");
    }

    /// @notice Get the worst case scenario duration for an instance of this contract
    /// @param _roundDuration security parameter, the max time an agent
    //          has to react and submit one simple transaction
    /// @param _timeToStartMachine time to build the machine for the first time
    function getMaxInstanceDuration(
        uint256 _roundDuration,
        uint256 _timeToStartMachine) public view returns (uint256)
    {
        uint256 waitingProofsDuration = getMaxStateDuration(
            state.WaitingProofs,
            _roundDuration,
            _timeToStartMachine
        );

        uint256 waitingReplayDuration = getMaxStateDuration(
            state.WaitingReplay,
            _roundDuration,
            _timeToStartMachine
        );

        uint256 finishProofsDuration = getMaxStateDuration(
            state.WaitingProofs,
            _roundDuration,
            _timeToStartMachine
        );

        return waitingProofsDuration + waitingReplayDuration + finishProofsDuration;
    }

    // remove these functions and change tests accordingly
    function stateIsWaitingProofs(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bool)
    { return instance[_index].currentState == state.WaitingProofs; }

    function stateIsWaitingReplay(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bool)
    { return instance[_index].currentState == state.WaitingReplay; }

    function stateIsFinishedReplay(uint256 _index) public view
        onlyInstantiated(_index)
        returns (bool)
    { return instance[_index].currentState == state.FinishedReplay; }
}
