namespace Titan.Core.Fsm;

public enum BatchProcessingState
{
    Idle,
    WaitEmpty,
    Loading,
    Settling,
    Locked,
    Printing,
    PostGuard,
    Paused
}

public enum PauseReason
{
    None,
    Manual,
    ReweighRequired,
    PrinterError,
    BatchStopped
}
