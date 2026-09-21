cmake_minimum_required(VERSION 3.24)
project(ProjectEmberLinux VERSION 0.1.0 LANGUAGES C CXX)

include(GNUInstallDirs)
include(CTest)

option(EMBER_ENABLE_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
if(EMBER_ENABLE_SANITIZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    message(FATAL_ERROR "EMBER_ENABLE_SANITIZERS requires GCC or Clang")
  endif()
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Widgets DBus)
if(BUILD_TESTING)
  find_package(Qt6 6.4 REQUIRED COMPONENTS Test)
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
if(BUILD_TESTING)
  pkg_check_modules(WAYLAND_SERVER REQUIRED IMPORTED_TARGET wayland-server)
endif()

find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

set(PROJECT_EMBER_EXECUTABLE "${CMAKE_INSTALL_FULL_BINDIR}/project-ember")
configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/packaging/project-ember.service.in
  ${CMAKE_CURRENT_BINARY_DIR}/project-ember.service
  @ONLY
)

set(CTM_XML ${CMAKE_CURRENT_SOURCE_DIR}/protocols/hyprland-ctm-control-v1.xml)
set(CTM_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
set(CTM_COMPAT_XML ${CTM_GENERATED_DIR}/hyprland-ctm-control-v1-scanner.xml)
file(MAKE_DIRECTORY ${CTM_GENERATED_DIR})
set(CTM_CLIENT_HEADER ${CTM_GENERATED_DIR}/hyprland-ctm-control-v1-client-protocol.h)
set(CTM_CLIENT_CODE ${CTM_GENERATED_DIR}/hyprland-ctm-control-v1-protocol.c)
set(CTM_SERVER_HEADER ${CTM_GENERATED_DIR}/hyprland-ctm-control-v1-server-protocol.h)
set(CTM_SERVER_CODE ${CTM_GENERATED_DIR}/hyprland-ctm-control-v1-server-protocol.c)

add_custom_command(
  OUTPUT ${CTM_CLIENT_HEADER} ${CTM_CLIENT_CODE} ${CTM_SERVER_HEADER} ${CTM_SERVER_CODE}
  COMMAND ${CMAKE_COMMAND} -DINPUT=${CTM_XML} -DOUTPUT=${CTM_COMPAT_XML} -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/NormalizeWaylandProtocol.cmake
  COMMAND ${WAYLAND_SCANNER} client-header ${CTM_COMPAT_XML} ${CTM_CLIENT_HEADER}
  COMMAND ${WAYLAND_SCANNER} private-code ${CTM_COMPAT_XML} ${CTM_CLIENT_CODE}
  COMMAND ${WAYLAND_SCANNER} server-header ${CTM_COMPAT_XML} ${CTM_SERVER_HEADER}
  COMMAND ${WAYLAND_SCANNER} private-code ${CTM_COMPAT_XML} ${CTM_SERVER_CODE}
  DEPENDS ${CTM_XML} ${CMAKE_CURRENT_SOURCE_DIR}/cmake/NormalizeWaylandProtocol.cmake
  VERBATIM
)
add_custom_target(ember_ctm_protocol DEPENDS ${CTM_CLIENT_HEADER} ${CTM_CLIENT_CODE} ${CTM_SERVER_HEADER} ${CTM_SERVER_CODE})

set_source_files_properties(${CTM_CLIENT_CODE} ${CTM_SERVER_CODE} PROPERTIES GENERATED TRUE LANGUAGE C)
add_library(ember_ctm_client STATIC ${CTM_CLIENT_CODE})
add_dependencies(ember_ctm_client ember_ctm_protocol)
target_include_directories(ember_ctm_client PUBLIC ${CTM_GENERATED_DIR})
target_link_libraries(ember_ctm_client PUBLIC PkgConfig::WAYLAND_CLIENT)
if(BUILD_TESTING)
  add_library(ember_ctm_server STATIC ${CTM_SERVER_CODE})
  add_dependencies(ember_ctm_server ember_ctm_protocol)
  target_include_directories(ember_ctm_server PUBLIC ${CTM_GENERATED_DIR})
  target_link_libraries(ember_ctm_server PUBLIC PkgConfig::WAYLAND_SERVER)
endif()

add_library(ember_domain STATIC
  src/core/Model.cpp
  src/core/Solar.cpp
  src/core/Persistence.cpp
  src/core/Recovery.cpp
  src/core/Diagnostics.cpp
  src/platform/Backlight.cpp
)
target_include_directories(ember_domain PUBLIC src ${CTM_GENERATED_DIR})
target_link_libraries(ember_domain PUBLIC Qt6::Core)
target_compile_options(ember_domain PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_library(ember_wayland STATIC
  src/platform/WaylandBackend.cpp
)
add_dependencies(ember_wayland ember_ctm_protocol)
target_include_directories(ember_wayland PUBLIC src ${CTM_GENERATED_DIR})
target_link_libraries(ember_wayland PUBLIC ember_domain ember_ctm_client Qt6::Core PkgConfig::WAYLAND_CLIENT)
target_compile_options(ember_wayland PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_library(ember_app STATIC
  src/AppController.cpp
  src/Ipc.cpp
  src/ui/SettingsDialog.cpp
  src/ui/DiagnosticsDialog.cpp
)
add_dependencies(ember_app ember_ctm_protocol)
target_include_directories(ember_app PUBLIC src ${CTM_GENERATED_DIR})
target_link_libraries(ember_app PUBLIC ember_wayland ember_domain Qt6::Core Qt6::Widgets Qt6::DBus PkgConfig::WAYLAND_CLIENT)
target_compile_options(ember_app PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(project-ember src/main.cpp)
target_include_directories(project-ember PRIVATE src ${CTM_GENERATED_DIR})
target_link_libraries(project-ember PRIVATE ember_app)
target_compile_options(project-ember PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

if(BUILD_TESTING)
  add_executable(ember-domain-tests tests/unit/DomainTests.cpp)
  target_include_directories(ember-domain-tests PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-domain-tests PRIVATE ember_domain Qt6::Core Qt6::Test)
  target_compile_definitions(ember-domain-tests PRIVATE EMBER_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
  target_compile_options(ember-domain-tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  add_test(NAME ember-domain-tests COMMAND ember-domain-tests)

  add_executable(ember-coordinator-tests tests/unit/CoordinatorTests.cpp)
  target_include_directories(ember-coordinator-tests PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-coordinator-tests PRIVATE ember_app Qt6::Core Qt6::Test)
  target_compile_options(ember-coordinator-tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  add_test(NAME ember-coordinator-tests COMMAND ember-coordinator-tests)

  add_executable(ember-wire-tests
    src/platform/WaylandBackend.cpp
    tests/integration/WireProtocolTests.cpp
  )
  add_dependencies(ember-wire-tests ember_ctm_protocol)
  target_include_directories(ember-wire-tests PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-wire-tests PRIVATE ember_domain ember_ctm_client ember_ctm_server Qt6::Core Qt6::Test PkgConfig::WAYLAND_CLIENT PkgConfig::WAYLAND_SERVER)
  target_compile_options(ember-wire-tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  add_test(NAME ember-wire-tests COMMAND ember-wire-tests)

  add_executable(ember-ipc-tests tests/integration/IpcTests.cpp)
  add_dependencies(ember-ipc-tests ember_ctm_protocol)
  target_include_directories(ember-ipc-tests PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-ipc-tests PRIVATE ember_app Qt6::Core Qt6::Test Qt6::DBus)
  target_compile_options(ember-ipc-tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  add_test(NAME ember-ipc-tests COMMAND ember-ipc-tests)

  add_executable(ember-process-recovery-tests tests/integration/ProcessRecoveryTests.cpp)
  target_include_directories(ember-process-recovery-tests PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-process-recovery-tests PRIVATE ember_domain Qt6::Core Qt6::Test)
  add_executable(ember-recovery-fixture tests/integration/RecoveryFixture.cpp)
  target_include_directories(ember-recovery-fixture PRIVATE src ${CTM_GENERATED_DIR})
  target_link_libraries(ember-recovery-fixture PRIVATE ember_domain Qt6::Core)
  target_compile_options(ember-recovery-fixture PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

  target_compile_definitions(ember-process-recovery-tests PRIVATE
    EMBER_PROJECT_BINARY="$<TARGET_FILE:project-ember>"
    EMBER_RECOVERY_FIXTURE="$<TARGET_FILE:ember-recovery-fixture>")
  target_compile_options(ember-process-recovery-tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  add_dependencies(ember-process-recovery-tests project-ember ember-recovery-fixture)
  add_test(NAME ember-process-recovery-tests COMMAND ember-process-recovery-tests)

  set_tests_properties(ember-domain-tests ember-coordinator-tests ember-wire-tests ember-ipc-tests ember-process-recovery-tests
    PROPERTIES TIMEOUT 30)
endif()

install(TARGETS project-ember RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES protocols/NOTICE DESTINATION ${CMAKE_INSTALL_DATADIR}/project-ember)
install(FILES packaging/app.projectember.Ember.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
# systemd's user unit directory is /usr/lib/systemd/user even on distributions
# whose CMake GNUInstallDirs uses an architecture-qualified library directory.
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/project-ember.service DESTINATION lib/systemd/user)
install(FILES packaging/project-ember.svg DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)
