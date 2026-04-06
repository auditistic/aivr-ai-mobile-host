#include <iostream>
#include <string>
#include <cassert>

extern "C" const char* get_mobile_status();

int main() {
    std::string status = get_mobile_status();
    std::cout << "Status: " << status << std::endl;
    std::string expected = "AIVR Mobile Backend (C++ Native) Active";
    if (status == expected) {
        std::cout << "Test Passed: Status matches expected value." << std::endl;
        return 0;
    } else {
        std::cerr << "Test Failed: Expected '" << expected << "', but got '" << status << "'" << std::endl;
        return 1;
    }
}
