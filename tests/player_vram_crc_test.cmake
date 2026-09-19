if(NOT EXISTS "${PLAYER}")
    message(FATAL_ERROR "player-sdl was not built: ${PLAYER}")
endif()

if(NOT EXISTS "${CART}")
    message(FATAL_ERROR "test cartridge was not found: ${CART}")
endif()

file(REMOVE "${OUTPUT}")
execute_process(
    COMMAND "${PLAYER}" --during 360 --vram-crc "${OUTPUT}" "${CART}"
    RESULT_VARIABLE player_result
    OUTPUT_VARIABLE player_stdout
    ERROR_VARIABLE player_stderr)

if(NOT player_result EQUAL 0)
    message(FATAL_ERROR
        "player-sdl failed with ${player_result}\nstdout:\n${player_stdout}\nstderr:\n${player_stderr}")
endif()

file(STRINGS "${OUTPUT}" checksums REGEX "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$")
list(LENGTH checksums checksum_count)
if(NOT checksum_count EQUAL EXPECTED_CRC_FRAMES)
    message(FATAL_ERROR
        "expected ${EXPECTED_CRC_FRAMES} checksum frames, got ${checksum_count}")
endif()
