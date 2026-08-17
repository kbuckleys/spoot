# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "Release")
  file(REMOVE_RECURSE
  "CMakeFiles/spoot_autogen.dir/AutogenUsed.txt"
  "CMakeFiles/spoot_autogen.dir/ParseCache.txt"
  "spoot_autogen"
  )
endif()
