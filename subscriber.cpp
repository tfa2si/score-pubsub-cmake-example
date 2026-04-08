// Minimal Subscriber using Eclipse S-Core MW / LoLA IPC
// Finds a service, subscribes to events, and prints motor angle samples.

#include "datatype.h"
#include "score/mw/com/runtime.h"
#include "score/mw/com/types.h"

#include <chrono>
#include <csignal>
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
        std::cerr << "Usage: subscriber <path/to/mw_com_config.json>\n";
        return EXIT_FAILURE;
    }

    const auto instance_specifier_result =
        score::mw::com::InstanceSpecifier::Create(std::string{"score/examples/MotorAngle"});
    if (!instance_specifier_result.has_value())
    {
        std::cerr << "Invalid instance specifier\n";
        return EXIT_FAILURE;
    }
    const auto& instance_specifier = instance_specifier_result.value();

    // Find the service (wait until available)
    std::cout << "[Subscriber] Looking for service...\n";
    score::mw::com::ServiceHandleContainer<score::mw::com::HandleType> handles;
    do
    {
        auto result = score::mw::com::MotorAngleProxy::FindService(instance_specifier);
        if (result.has_value())
        {
            handles = std::move(result).value();
        }
        if (handles.empty())
        {
            std::this_thread::sleep_for(500ms);
        }
    } while (handles.empty() && g_running);

    if (handles.empty())
    {
        return EXIT_SUCCESS;
    }

    std::cout << "[Subscriber] Service found. Connecting...\n";
    auto proxy_result = score::mw::com::MotorAngleProxy::Create(std::move(handles.front()));
    if (!proxy_result.has_value())
    {
        std::cerr << "[Subscriber] Failed to create proxy: " << proxy_result.error() << "\n";
        return EXIT_FAILURE;
    }
    auto& proxy = proxy_result.value();

    // Subscribe to the event
    constexpr std::size_t kMaxSamples = 5U;
    if (!proxy.motor_angle_.Subscribe(kMaxSamples).has_value())
    {
        std::cerr << "[Subscriber] Failed to subscribe\n";
        return EXIT_FAILURE;
    }

    // Event-driven callback: triggered by middleware when new samples arrive
    proxy.motor_angle_.SetReceiveHandler([&proxy]() noexcept {
        constexpr std::size_t kBatch = 10U;
        const auto result = proxy.motor_angle_.GetNewSamples(
            [](score::mw::com::SamplePtr<score::mw::com::MotorAngle> sample) noexcept {
                std::cout << "[Subscriber] Received motor angle [deg]: " << sample->angle_deg << "\n";
            },
            kBatch);

        if (!result.has_value())
        {
            std::cerr << "[Subscriber] GetNewSamples failed: " << result.error() << "\n";
        }
    });

    std::cout << "[Subscriber] Subscribed. Waiting for events...\n";

    // Keep process alive; no polling of GetNewSamples in a timed loop
    while (g_running)
    {
        std::this_thread::sleep_for(1s);
    }

    proxy.motor_angle_.UnsetReceiveHandler();
    proxy.motor_angle_.Unsubscribe();
    std::cout << "[Subscriber] Unsubscribed. Bye!\n";
    return EXIT_SUCCESS;
}
