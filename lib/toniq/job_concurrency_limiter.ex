defmodule Toniq.JobConcurrencyLimiter do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  "run" gets called by all client processes. E.g. if you enqueue 10000 jobs, this
  gets called 10000 times. Each call tells the concurrency limiter about itself and
  waits for it's turn to run.

  The limiter keeps a count of running jobs and if there are more running jobs than
  the max_concurrency limit, then the jobs are stored for later.

  When a job is done this function tells the limiter about it by calling
  "confirm_run" which updates the current state and allows another job to run.
  """
  def run(job),                       do: run(job, job.worker.max_concurrency)
  defp run(job, :unlimited),          do: run_job_process(job)
  defp run(job, _has_max_concurrency) do
    request_run(job)

    receive do
      {:run, job} ->
        result = run_job_process(job)
        confirm_run(job)
        result
    end
  end

  defp run_job_process(job), do: Toniq.JobProcess.run(job)

  defp request_run(job) do
    GenServer.cast(__MODULE__, {:request_run, job, self})
  end

  defp confirm_run(job) do
    GenServer.cast(__MODULE__, {:confirm_run, job})
  end

  def handle_cast({:request_run, job, caller}, state) do
    state =
      if below_max_concurrency?(state, job) do
        run_now(state, {job, caller})
      else
        run_later(state, {job, caller})
      end

    {:noreply, state}
  end

  def handle_cast({:confirm_run, job}, state) do
    state = decrease_running_count(state, job)

    state =
      if below_max_concurrency?(state, job) do
        run_next_pending_job(state, job)
      else
        state
      end

    {:noreply, state}
  end

  defp run_next_pending_job(state, job),     do: run_next_pending_job(state, job, pending_jobs(state, job))
  defp run_next_pending_job(state, job, []), do: state
  defp run_next_pending_job(state, job, pending_jobs_by_worker) do
    [ first_pending_job | pending_jobs ] = pending_jobs_by_worker

    state = run_now(state, first_pending_job)

    worker_state = worker_state(state, job)
    update_worker_state(state, job,
      %{ worker_state | pending_jobs: pending_jobs }
    )
  end

  defp run_now(state, {job, caller}) do
    send caller, {:run, job}
    increase_running_count(state, job)
  end

  defp run_later(state, {job, caller}) do
    worker_state = worker_state(state, job)
    update_worker_state(state, job,
      %{ worker_state | pending_jobs: worker_state.pending_jobs ++ [ {job, caller} ] }
    )
  end

  defp below_max_concurrency?(state, job) do
    running_count(state, job) < job.worker.max_concurrency
  end

  defp increase_running_count(state, job) do
    update_running_count(state, job, +1)
  end

  defp decrease_running_count(state, job) do
    update_running_count(state, job, -1)
  end

  defp update_running_count(state, job, difference) do
    running_count = running_count(state, job) + difference

    worker_state = worker_state(state, job)
    state = update_worker_state(state, job,
      %{ worker_state | running_count: running_count }
    )

    if running_count < 0 do
      raise "Job count should never be able to be less than zero, state is: #{inspect(state)}"
    end

    state
  end

  defp update_worker_state(state, job, worker_state) do
    Map.put(state, job.worker, worker_state)
  end

  defp running_count(state, job), do: worker_state(state, job).running_count
  defp pending_jobs(state, job), do: worker_state(state, job).pending_jobs

  defp worker_state(state, job) do
    Map.get(state, job.worker, %{ pending_jobs: [], running_count: 0 })
  end
end
