if(NOT EXISTS "${PLAYER}")
    message(FATAL_ERROR "player-sdl was not built: ${PLAYER}")
endif()

if(NOT EXISTS "${CART}")
    message(FATAL_ERROR "test cartridge was not found: ${CART}")
endif()

function(run_player output)
    file(REMOVE "${output}")
    execute_process(
        COMMAND "${PLAYER}" --during 360 --vram-crc "${output}" "${CART}"
        RESULT_VARIABLE player_result
        OUTPUT_VARIABLE player_stdout
        ERROR_VARIABLE player_stderr)

    if(NOT player_result EQUAL 0)
        message(FATAL_ERROR
            "player-sdl failed with ${player_result}\nstdout:\n${player_stdout}\nstderr:\n${player_stderr}")
    endif()
endfunction()

run_player("${OUTPUT_A}")
run_player("${OUTPUT_B}")

file(STRINGS "${OUTPUT_A}" checksums_a REGEX "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$")
file(STRINGS "${OUTPUT_B}" checksums_b REGEX "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$")
list(LENGTH checksums_a checksum_count)
if(NOT checksum_count EQUAL EXPECTED_CRC_FRAMES)
    message(FATAL_ERROR
        "expected ${EXPECTED_CRC_FRAMES} checksum frames, got ${checksum_count}")
endif()

if(NOT checksums_a STREQUAL checksums_b)
    message(FATAL_ERROR "separate deterministic player runs produced different VRAM checksums")
endif()
