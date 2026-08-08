#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <thread>

#include "s7_server.h"

static std::atomic<bool> running(true);

static void stop_server(int) {
  running = false;
}

int main(int argc, char **argv) {
  word port = argc > 1 ? static_cast<word>(std::atoi(argv[1])) : 11102;
  static byte db1[512] = {0};
  static byte inputs[512] = {0};
  static byte outputs[512] = {0};
  static byte markers[512] = {0};

  db1[0] = 0x04;
  db1[1] = 0xD2;
  inputs[0] = 0x80;

  TSnap7Server server;

  if (server.SetParam(p_u16_LocalPort, &port) != 0 ||
      server.RegisterArea(srvAreaDB, 1, db1, sizeof(db1)) != 0 ||
      server.RegisterArea(srvAreaPE, 0, inputs, sizeof(inputs)) != 0 ||
      server.RegisterArea(srvAreaPA, 0, outputs, sizeof(outputs)) != 0 ||
      server.RegisterArea(srvAreaMK, 0, markers, sizeof(markers)) != 0) {
    return 2;
  }

  if (server.StartTo("127.0.0.1") != 0) {
    return 3;
  }

  std::signal(SIGINT, stop_server);
  std::signal(SIGTERM, stop_server);
  std::cout << "READY " << port << std::endl;

  while (running) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  server.Stop();
  return 0;
}
