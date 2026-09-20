if(NOT DEFINED INPUT OR NOT DEFINED OUTPUT)
  message(FATAL_ERROR "INPUT and OUTPUT are required")
endif()
file(READ "${INPUT}" protocol)
# Wayland 1.22 (still shipped by some LTS distributions) rejects the `version`
# attribute on event declarations even though the v2 interface version remains
# authoritative. Keep the vendored upstream XML unchanged and normalize only
# this parser spelling for the local scanner.
string(REPLACE "<event name=\"blocked\" version=\"2\">" "<event name=\"blocked\">" protocol "${protocol}")
string(REPLACE "<description>\n        This event is sent if another manager" "<description summary=\"blocked event\">\n        This event is sent if another manager" protocol "${protocol}")
file(WRITE "${OUTPUT}" "${protocol}")
