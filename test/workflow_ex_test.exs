defmodule WorkflowExTest do
  use ExUnit.Case
  use AssertEventually, timeout: 50, interval: 5

  import Mox

  alias WorkflowEx.TestState
  alias WorkflowEx.Fields

  doctest WorkflowEx
  @moduletag :capture_log

  setup do
    Process.flag(:trap_exit, true)
    {:ok, %{test_steps: TestState.new()}}
  end

  defmodule JustStart do
    use WorkflowEx, steps: [WorkflowEx.StepOk, WorkflowEx.StepOk2]
  end

  describe "route\4" do
    @first_step 0
    @last_step 1
    @second_step 1

    [
      {nil, :ok, :up, @first_step, {:ok, :handle_init}, %{}},
      {:handle_init, :ok, :up, @first_step, {:continue, :execute_step}, %{}},
      {:step, :ok, :up, @first_step, {:continue, :execute_step}, %{step_index: @second_step, step_func: :run}},
      {:step, :ok, :up, @last_step, {:continue, :handle_workflow_success}, %{}},
      {:step, :ok, :down, @first_step, {:continue, :handle_workflow_failure}, %{}},
      {:step, :ok, :down, @second_step, {:continue, :execute_step}, %{step_index: @first_step, step_func: :rollback}},
      {:step, :continue, :up, @first_step, :noreply, %{step_index: @first_step, step_func: :run_continue}},
      {:step, :continue, :down, @first_step, :noreply, %{step_index: @first_step, step_func: :rollback_continue}},
      {:step, :er, :up, @first_step, {:continue, :execute_start_rollback},
       %{
         step_index: @first_step,
         step_func: :rollback,
         flow_direction: :down,
         flow_error_reason: :er
       }},
      {:handle_start_rollback, :er, :down, @first_step, {:continue, :execute_step}, %{}},
      {:step, :er, :down, @first_step, {:stop, :er}, %{}},
      {:rollback, :er, :up, @first_step, {:continue, :execute_step},
       %{
         step_index: @first_step,
         step_func: :rollback,
         flow_direction: :down,
         flow_error_reason: :er
       }},
      {:rollback, :er, :down, @first_step, :noreply, %{}}
    ]
    |> Enum.map(fn {src, result, direction, current_step, expected_response, expected_state} ->
      @src src
      @result result
      @direction direction
      @current_step current_step
      @expected_response expected_response
      @expected_state expected_state

      test "src: #{src}, result: #{result}, dir: #{direction}, step: #{if current_step == @first_step, do: "first", else: "last"} should return #{inspect(expected_response)}}" do
        test_steps =
          TestState.new!(%{
            __flow__: %{
              lifecycle_src: @src,
              last_result: @result,
              flow_direction: @direction,
              step_index: @current_step
            }
          })

        updated_state =
          case @expected_response do
            {:continue, step} ->
              assert {:noreply, updated_state, {:continue, ^step}} = JustStart.route(test_steps)
              updated_state

            {:ok, :handle_init} ->
              assert {:ok, updated_state, {:continue, :handle_init}} = JustStart.route(test_steps)
              updated_state

            {:stop, error} ->
              assert {:stop, ^error, updated_state} = JustStart.route(test_steps)
              updated_state

            :noreply ->
              assert {:noreply, updated_state} = JustStart.route(test_steps)
              updated_state
          end

        assert @expected_state = Fields.take(updated_state, Map.keys(@expected_state))
      end
    end)
  end

  describe "when init-ing a workflow" do
    test "will continue to the workflow", %{test_steps: test_steps} do
      assert {:ok, test_steps, {:continue, :handle_init}} == JustStart.init(test_steps)
    end

    test "when trying to start a workflow w/ a state that is missing the required fields, halt" do
      assert {:stop, :missing_flow_fields} == JustStart.init(%{})
    end
  end

  describe "a synchronous, successful workflow with no observer steps or finalizer" do
    defmodule SyncSuccess do
      use WorkflowEx, steps: [WorkflowEx.StepOk, WorkflowEx.StepOk2]
    end

    test "the GenServer workflow runs to completion and stops", %{test_steps: test_steps} do
      assert {:ok, pid} = SyncSuccess.start_link(test_steps)
      assert_receive {:EXIT, ^pid, :normal}
      final_state = StateAgent.get(test_steps.agent)

      assert final_state.execution_order == [
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.StepOk2, :run}
             ]
    end
  end

  describe "a synchronous, failing workflow with no observer steps or finalizer" do
    defmodule SyncFailure do
      use WorkflowEx,
        steps: [WorkflowEx.StepOk, WorkflowEx.StepError]
    end

    test "the workflow rollsback", %{test_steps: test_steps} do
      assert {:ok, pid} = SyncFailure.start_link(test_steps)
      # completed normally because rollback succeeded
      assert_receive {:EXIT, ^pid, :error}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.StepError, :run},
               {WorkflowEx.StepError, :rollback},
               {WorkflowEx.StepOk, :rollback}
             ]
    end
  end

  describe "an async, succeeding workflow with no observer steps or finalizer" do
    defmodule AsyncSuccess do
      use WorkflowEx,
        steps: [
          WorkflowEx.StepOk,
          WorkflowEx.AsyncStepOk
        ]
    end

    test "the workflow runs, pauses, and then succeeds when the message is received", %{test_steps: test_steps} do
      # act 1
      assert {:ok, pid} = AsyncSuccess.start_link(test_steps)

      # assert
      # after the first pause-step:
      assert_eventually(
        [
          {WorkflowEx.StepOk, :run},
          {WorkflowEx.AsyncStepOk, :run}
        ] == StateAgent.get(test_steps.agent).execution_order
      )

      # act 2 - now continue processing by sending the expected continue message
      send(pid, WorkflowEx.AsyncStepOk)

      # completed normally as expected
      assert_receive {:EXIT, ^pid, :normal}

      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.AsyncStepOk, :run},
               {WorkflowEx.AsyncStepOk, :run_continue}
             ]
    end
  end

  describe "Failing asynchronous workflow rolls back automatically" do
    defmodule AsyncFailureRollsBack do
      use WorkflowEx,
        steps: [
          WorkflowEx.StepOk,
          WorkflowEx.AsyncStepOk,
          WorkflowEx.AsyncStepError
        ]
    end

    test "the workflow runs, pauses, the async step fails, and reverses direction", %{test_steps: test_steps} do
      # act 1
      assert {:ok, pid} = AsyncFailureRollsBack.start_link(test_steps)

      send(pid, WorkflowEx.AsyncStepOk)
      send(pid, WorkflowEx.AsyncStepError)

      assert_receive {:EXIT, ^pid, :error}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.AsyncStepOk, :run},
               {WorkflowEx.AsyncStepOk, :run_continue},
               {WorkflowEx.AsyncStepError, :run},
               {WorkflowEx.AsyncStepError, :run_continue},
               {WorkflowEx.AsyncStepError, :rollback},
               {WorkflowEx.AsyncStepOk, :rollback},
               {WorkflowEx.StepOk, :rollback}
             ]
    end

    test "the workflow runs, and if told to rollback from a separate handler, does so w/out running any further than necessary",
         %{test_steps: test_steps} do
      assert {:ok, pid} = AsyncFailureRollsBack.start_link(test_steps)

      send(pid, WorkflowEx.AsyncStepOk)
      send(pid, {:rollback, :external_error})
      assert_receive {:EXIT, ^pid, :external_error}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.AsyncStepOk, :run},
               {WorkflowEx.AsyncStepOk, :run_continue},
               {WorkflowEx.AsyncStepError, :run},

               # this one is never run
               # {WorkflowEx.AsyncStepError, :run_continue},

               {WorkflowEx.AsyncStepError, :rollback},
               {WorkflowEx.AsyncStepOk, :rollback},
               {WorkflowEx.StepOk, :rollback}
             ]
    end
  end

  describe "a synchronous, successful workflow with observer steps" do
    defmodule SyncObserverSuccess do
      use WorkflowEx,
        steps: [WorkflowEx.StepOk, WorkflowEx.StepOk2],
        observers: [WorkflowEx.TestObserver, WorkflowEx.TestObserver2]
    end

    test "observer steps are all run", %{test_steps: test_steps} do
      assert {:ok, pid} = SyncObserverSuccess.start_link(test_steps)

      assert_receive {:EXIT, ^pid, :normal}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.TestObserver, :handle_init},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.TestObserver2, :handle_before_step},
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver2, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.TestObserver2, :handle_before_step},
               {WorkflowEx.StepOk2, :run},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver2, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_workflow_success}
             ]
    end

    test "flow can be started directly in rollback", %{test_steps: test_steps} do
      test_steps =
        Fields.merge(test_steps, %{
          flow_direction: :up,
          life_cycle_src: :step,
          last_result: :ok,
          step_index: 1,
          step_func: :run
        })
        |> WorkflowEx.rollback(:because_reasons)

      assert {:ok, pid} = SyncObserverSuccess.start_link(test_steps)

      assert_receive {:EXIT, ^pid, :because_reasons}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.TestObserver2, :handle_before_step},
               {WorkflowEx.StepOk2, :rollback},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver2, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.TestObserver2, :handle_before_step},
               {WorkflowEx.StepOk, :rollback},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver2, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_workflow_failure}
             ]
    end
  end

  describe "a synchronous workflow with observer steps that raise can't stop the workflow" do
    defmodule SyncObserverRaise do
      use WorkflowEx,
        steps: [WorkflowEx.StepOk],
        observers: [WorkflowEx.RaisingObserver]
    end

    test "when run", %{test_steps: test_steps} do
      assert {:ok, pid} = SyncObserverRaise.start_link(test_steps)

      assert_receive {:EXIT, ^pid, :normal}
      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.RaisingObserver, :handle_init},
               {WorkflowEx.RaisingObserver, :handle_before_step},
               {WorkflowEx.StepOk, :run},
               {WorkflowEx.RaisingObserver, :handle_after_step},
               {WorkflowEx.RaisingObserver, :handle_after_workflow_success}
             ]
    end
  end

  describe "an asynchronous, successful workflow with after steps" do
    defmodule AsyncSuccessWithObservers do
      use WorkflowEx,
        on_exit: MockExitHandler,
        steps: [WorkflowEx.AsyncStepOk],
        observers: [WorkflowEx.TestObserver]
    end

    setup :set_mox_from_context

    test "the expected steps and observers all fire", %{test_steps: test_steps} do
      test_pid = self()

      MockExitHandler
      |> expect(:on_exit, fn :normal = reason, state ->
        send(test_pid, {:on_exit, reason, state})
        :result_from_exit_handler
      end)

      assert {:ok, pid} = AsyncSuccessWithObservers.start_link(test_steps)
      send(pid, WorkflowEx.AsyncStepOk)

      assert_receive {:on_exit, :normal, state}
      assert state.__flow__.flow_error_reason == :normal

      assert_receive {:EXIT, ^pid, :result_from_exit_handler}

      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.TestObserver, :handle_init},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.AsyncStepOk, :run},
               {WorkflowEx.AsyncStepOk, :run_continue},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_workflow_success}
             ]
    end
  end

  describe "a synchronous, failing workflow with a working handle_workflow_failure observer" do
    defmodule SyncHandleFailureObserverSuccess do
      use WorkflowEx,
        on_exit: MockExitHandler,
        steps: [WorkflowEx.StepError],
        observers: [WorkflowEx.TestObserver]
    end

    setup :set_mox_from_context

    test "runs handle_workflow_failure successfully", %{test_steps: test_steps} do
      test_pid = self()

      MockExitHandler
      |> expect(:on_exit, fn :error = reason, state ->
        send(test_pid, {:on_exit, reason, state})
        :result_from_exit_handler
      end)

      assert {:ok, pid} = SyncHandleFailureObserverSuccess.start_link(test_steps)

      assert_receive {:on_exit, :error, state}
      assert state.__flow__.flow_error_reason == :error

      assert_receive {:EXIT, ^pid, :result_from_exit_handler}

      flow_state = StateAgent.get(test_steps.agent)

      assert flow_state.execution_order == [
               {WorkflowEx.TestObserver, :handle_init},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.StepError, :run},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_start_rollback},
               {WorkflowEx.TestObserver, :handle_before_step},
               {WorkflowEx.StepError, :rollback},
               {WorkflowEx.TestObserver, :handle_after_step},
               {WorkflowEx.TestObserver, :handle_workflow_failure}
             ]
    end
  end

  test "in_rollback?" do
    state =
      TestState.new()
      |> Fields.merge(%{direction: :up})

    refute WorkflowEx.in_rollback?(state)

    state = Fields.merge(state, %{flow_direction: :down})
    assert WorkflowEx.in_rollback?(state)
  end

  test "rollback\1 ensures that any state that comes in leaves in rollback mode" do
    state =
      TestState.new()
      |> Fields.merge(%{direction: :up})
      |> WorkflowEx.rollback(:because_i_said_so)

    assert Fields.take(state, ~w[flow_direction step_func last_result lifecycle_src]a) == %{
             flow_direction: :up,
             step_func: :rollback,
             last_result: :because_i_said_so,
             lifecycle_src: :rollback
           }
  end
end
