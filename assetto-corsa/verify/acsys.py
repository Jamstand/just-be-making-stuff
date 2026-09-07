class GL: Lines, LineStrip, Triangles, Quads = range(4)
class CS:
    (SpeedMS, SpeedMPH, SpeedKMH, Gas, Brake, Clutch, Gear, Aero, BestLap,
     CamberRad, AccG, CGHeight, DriftBestLap, DriftLastLap, DriftPoints,
     DriveTrainSpeed, DY, RPM, Load, InstantDrift, IsDriftInvalid,
     IsEngineLimiterOn, LapCount, LapInvalidated, LapTime, LastFF, LastLap,
     LocalAngularVelocity, LocalVelocity, Mz, NdSlip, NormalizedSplinePosition,
     PerformanceMeter, SlipAngle, SlipAngleContactPatch, SlipRatio, SpeedTotal,
     Steer, SuspensionTravel, TurboBoost, TyreDirtyLevel, TyreContactNormal,
     TyreContactPoint, TyreHeadingVector, TyreLoadedRadius, TyreRadius,
     TyreRightVector, TyreSlip, TyreSurfaceDef, TyreVelocity, Velocity,
     WheelAngularSpeed, WorldPosition, Caster, CurrentTyresCoreTemp,
     LastTyresTemp, DynamicPressure, RideHeight, ToeInDeg, CamberDeg,
     KersCharge, KersInput, DrsAvailable, DrsEnabled, EngineBrake,
     ERSRecovery, ERSDelivery, ERSHeatCharging, ERSCurrentKJ, ERSMaxJ,
     RaceFinished, P2PStatus, P2PActivations) = range(73)
class WHEELS: FL, FR, RL, RR = range(4)
