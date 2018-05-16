defmodule HordeSupervisorTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, horde_1} = Horde.Supervisor.start_link([], node_id: :horde_1, strategy: :one_for_one)
    {:ok, horde_2} = Horde.Supervisor.start_link([], node_id: :horde_2, strategy: :one_for_one)
    {:ok, horde_3} = Horde.Supervisor.start_link([], node_id: :horde_3, strategy: :one_for_one)

    Horde.Tracker.join_hordes(horde_1, horde_2)
    Horde.Tracker.join_hordes(horde_3, horde_2)

    # give the processes a couple ms to sync up
    Process.sleep(20)

    pid = self()

    task_def = %{
      id: :proc_1,
      start:
        {Task, :start_link,
         [
           fn ->
             send(pid, {:process_started, self()})
             Process.sleep(100)
           end
         ]},
      type: :worker,
      restart: :transient
    }

    [
      horde_1: horde_1,
      horde_2: horde_2,
      horde_3: horde_3,
      task_def: task_def
    ]
  end

  test "can start a process", context do
    Horde.Supervisor.start_child(context.horde_1, context.task_def)

    assert_receive {:process_started, _pid}
  end

  test "failed process is restarted", context do
    Horde.Supervisor.start_child(context.horde_1, context.task_def)
    assert_receive {:process_started, pid}
    Process.exit(pid, :kill)
    assert_receive {:process_started, _pid}
  end

  test "processes are started on different nodes", context do
    1..10
    |> Enum.each(fn x ->
      Horde.Supervisor.start_child(context.horde_1, Map.put(context.task_def, :id, :"proc_#{x}"))
    end)

    supervisor_pids =
      1..10
      |> Enum.map(fn _ ->
        assert_receive {:process_started, task_pid}
        {:links, [supervisor_pid]} = task_pid |> Process.info(:links)
        supervisor_pid
      end)
      |> Enum.uniq()

    assert Enum.uniq(supervisor_pids) |> Enum.count() > 1
  end

  test ".count_children/1", context do
    1..10
    |> Enum.each(fn x ->
      Horde.Supervisor.start_child(context.horde_1, Map.put(context.task_def, :id, :"proc_#{x}"))
    end)

    assert %{workers: 10} = Horde.Supervisor.count_children(context.horde_1)
  end

  test "failed horde's processes are taken over by other hordes", context do
    1..100
    |> Enum.each(fn x ->
      Horde.Supervisor.start_child(context.horde_1, Map.put(context.task_def, :id, :"proc_#{x}"))
    end)

    Process.unlink(context.horde_2)
    Process.exit(context.horde_2, :kill)

    %{workers: workers} = Horde.Supervisor.count_children(context.horde_1)
    IO.inspect({:number_of_workers, workers})
    assert workers < 100

    Process.sleep(100)

    assert %{workers: 100} = Horde.Supervisor.count_children(context.horde_1)
  end

  test "exiting horde's processes are gracefully moved to another horde"
end
