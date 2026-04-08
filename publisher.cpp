// Minimal Publisher using Eclipse S-Core MW / LoLA IPC
// Offers a service and continuously sends MotorAngle samples.

#include "datatype.h"
#include "score/mw/com/runtime.h"
#include "score/mw/com/types.h"

#include <chrono>
#include <csignal>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <thread>

using namespace std::chrono_literals;

static volatile bool g_running = true;

static void signal_handler(int /*sig*/)
{
    g_running = false;
}

int main(int argc, const char** argv)
{
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    // Initialize LoLA runtime with the service instance manifest
    if (argc > 1)
    {
        score::StringLiteral runtime_args[2u] = {"--service_instance_manifest", argv[1]};
        score::mw::com::runtime::InitializeRuntime(2, runtime_args);
    }
    else
    {
        std::cerr << "Usage: publisher <path/to/mw_com_config.json>\n";
        return EXIT_FAILURE;
    }

    // Create and offer the service skeleton
    const auto instance_specifier_result =
        score::mw::com::InstanceSpecifier::Create(std::string{"score/examples/MotorAngle"});
    if (!instance_specifier_result.has_value())
    {
        std::cerr << "Invalid instance specifier\n";
        return EXIT_FAILURE;
    }

    auto skeleton_result = score::mw::com::MotorAngleSkeleton::Create(instance_specifier_result.value());
    if (!skeleton_result.has_value())
    {
        std::cerr << "Failed to create skeleton: " << skeleton_result.error() << "\n";
        return EXIT_FAILURE;
    }
    auto& skeleton = skeleton_result.value();

    if (!skeleton.OfferService().has_value())
    {
        std::cerr << "Failed to offer service\n";
        return EXIT_FAILURE;
    }

    std::cout << "[Publisher] Service offered. Sending data...\n";

    double t = 0.0;
    const double freq = 1.0;  // 1 Hz
    const double dt   = 0.05; // 50 ms per step
    while (g_running)
    {
        auto sample_result = skeleton.motor_angle_.Allocate();
        if (!sample_result.has_value())
        {
            std::cerr << "[Publisher] Failed to allocate sample\n";
            break;
        }
        auto sample = std::move(sample_result).value();
        const float angle_deg = static_cast<float>(90.0 * std::sin(2.0 * M_PI * freq * t));
        sample->angle_deg = angle_deg;

        const auto send_result = skeleton.motor_angle_.Send(std::move(sample));
        if (send_result.has_value())
        {
            std::cout << "[Publisher] Sent motor angle [deg]: " << angle_deg << "\n";
        }
        else
        {
            std::cerr << "[Publisher] Send failed: " << send_result.error() << "\n";
        }

        t += dt;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    std::cout << "[Publisher] Stopping service...\n";
    skeleton.StopOfferService();
    return EXIT_SUCCESS;
}
