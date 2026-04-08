/********************************************************************************
 * Copyright (c) 2025 Contributors to the Eclipse Foundation
 *
 * See the NOTICE file(s) distributed with this work for additional
 * information regarding copyright ownership.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/
#ifndef SCORE_MINIMAL_SCORE_PUBSUB_DATATYPE_H
#define SCORE_MINIMAL_SCORE_PUBSUB_DATATYPE_H

#include "score/mw/com/types.h"

namespace score::mw::com
{

struct MotorAngle
{
    MotorAngle() = default;

    MotorAngle(MotorAngle&&) = default;

    MotorAngle(const MotorAngle&) = default;

    MotorAngle& operator=(MotorAngle&&) = default;

    MotorAngle& operator=(const MotorAngle&) = default;

    float angle_deg{0.0F};
};

template <typename Trait>
class MotorAngleInterface : public Trait::Base
{
  public:
    using Trait::Base::Base;

    typename Trait::template Event<MotorAngle> motor_angle_{*this, "motor_angle"};
};

using MotorAngleProxy = AsProxy<MotorAngleInterface>;
using MotorAngleSkeleton = AsSkeleton<MotorAngleInterface>;

}  // namespace score::mw::com

#endif  // SCORE_MINIMAL_SCORE_PUBSUB_DATATYPE_H
