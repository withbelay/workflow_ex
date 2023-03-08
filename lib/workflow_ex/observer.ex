defmodule WorkflowEx.Observer do
  @moduledoc """
  Provides default implementations for the lifecycle of the workflow, and marks it as implementing the appropriate behaviour
  """
  @callback handle_init(WorkflowEx.flow_state()) :: {:ok | :error | atom(), WorkflowEx.flow_state()}
  @callback handle_before_step(WorkflowEx.flow_state()) :: {:ok | :error | atom(), WorkflowEx.flow_state()}
  @callback handle_after_step(WorkflowEx.flow_state()) :: {:ok | :error | atom(), WorkflowEx.flow_state()}
  @callback handle_workflow_success(WorkflowEx.flow_state()) :: {:ok | :error | atom(), WorkflowEx.flow_state()}
  @callback handle_workflow_failure(WorkflowEx.flow_state()) :: {:ok | :error | atom(), WorkflowEx.flow_state()}
  defmacro __using__(_) do
    quote do
      @behaviour WorkflowEx.Observer

      @impl true
      def handle_init(state), do: {:ok, state}

      @impl true
      def handle_before_step(state), do: {:ok, state}

      @impl true
      def handle_after_step(state), do: {:ok, state}

      @impl true
      def handle_workflow_success(state), do: {:ok, state}

      @impl true
      def handle_workflow_failure(state), do: {:ok, state}

      defoverridable handle_init: 1,
                     handle_before_step: 1,
                     handle_after_step: 1,
                     handle_workflow_success: 1,
                     handle_workflow_failure: 1
    end
  end
end