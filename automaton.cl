#define ID_FAIL 0
#define ID_OK 1
#define ID_BEGIN 2
#define RESULT_FAIL 0xffffffff
#define MAX_ITER_COUNT 512
#define MAX_STACK_SIZE 16
#define FLAG_STACK_FULL 0
#define FLAG_ITER_MAX 1
#define SYNC_COUNT 32

bool is_master() {
    return get_local_id(0) == 0;
}

uint find_next_slot(uint state, uint element, uint n, uint m, uint o, __constant uint* automatonData) {
    uint base_node = state * m * (1 + o);

    bool found = false;

    uint idx_next = 0;
    uint base_next = base_node + idx_next * (1 + o);
    uint x_next = automatonData[base_next];

    uint idx_current = idx_next; // exception for first round
    uint base_current = base_next;
    uint x_current = x_next;

    while (idx_current + 1 < m && !found) {
        idx_current = idx_next;
        base_current = base_next;
        x_current = x_next;

        idx_next = idx_current + 1;
        base_next = base_node + idx_next * (1 + o);
        x_next = automatonData[base_next];

        if (element >= x_current && element < x_next) {
            found = true;
        }
    }

    if (found) {
        uint base_slot = base_current + 1;
        return base_slot;
    } else {
        return 0;
    }
}

uint state_from_slot(uint idx, uint base_slot, uint n, __constant uint* automatonData) {
    uint base_entry = base_slot + idx;
    uint next_state = automatonData[base_entry];
    if (next_state < n) {
        return next_state;
    } else {
        return ID_FAIL;
    }
}

struct stack_entry {
    uint startpos;
    uint pos;
    uint state;
};

bool sync(__local uint* active_count, uint iter_count) {
    // do not sync every cycle
    if (iter_count % SYNC_COUNT == 0) {
        barrier(CLK_LOCAL_MEM_FENCE);
        uint current_active_count = *active_count;
        barrier(CLK_LOCAL_MEM_FENCE);

        return current_active_count > 0;
    } else {
        return true;
    }
}

__kernel void automaton(uint n,
                        uint m,
                        uint o,
                        uint size,
                        uint multi_input_n,
                        __constant uint* automatonData,
                        __global const uint* text,
                        __global uint* output,
                        __global char* flags,
                        __local uint* cache) {
    // constants
    const uint base_group = get_group_id(0) * multi_input_n * get_local_size(0);

    // private thread-local state
    __private struct stack_entry stack[MAX_STACK_SIZE];
    uint stack_size = 0;
    uint iter_count = 0;

    // cache preparation
    __local uint active_count;
    __local uint base_cache;
    if (is_master()) {
        active_count = get_local_size(0);
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // push initial work to stack
    for (uint i = multi_input_n; i > 0; --i) {
        // [group_0: [i_0: [thread_0|...|thread_z] | ... | [i_y: thread_0|...|thread_z]]]
        // | ... |
        // [group_x: [i_0: [thread_0|...|thread_z] | ... | [i_y: thread_0|...|thread_z]]]
        uint startpos = base_group + (i - 1) * get_local_size(0) + get_local_id(0);

        if (startpos < size) {
            // push to stack
            stack[stack_size].startpos = startpos;
            stack[stack_size].pos = startpos;
            stack[stack_size].state = ID_BEGIN;
            stack_size += 1;

            // write failed state, in case no task will finish
            output[startpos] = RESULT_FAIL;
        }
    }
    if (stack_size == 0) {
        atomic_dec(&active_count);
    }

    // stack is ordered, so same startpos values will be grouped together
    // use this knowledge for branch pruning in case we ware successful
    uint prune = 0xffffffff;

    // run until stack is empty
    bool work_left = true;
    while (work_left && iter_count < MAX_ITER_COUNT) {
        // 1. sync
        work_left = sync(&active_count, iter_count);

        // 2. do thread-local work
        if (stack_size > 0) {
            // pop from stack
            stack_size -= 1;
            uint startpos = stack[stack_size].startpos;
            uint pos = stack[stack_size].pos;
            uint state = stack[stack_size].state;

            // variant a) we've finished
            if (state == ID_OK) {
                output[startpos] = startpos;
                prune = startpos;
            } else if (startpos != prune && state != ID_FAIL && pos < size) { // variant b) get next states
                // run automaton one step
                uint element = text[pos];
                uint base_slot = find_next_slot(state, element, n, m, o, automatonData);

                // decide what to do next
                if (base_slot != 0) {
                    // first decision gues to this "thread"
                    state = state_from_slot(0, base_slot, n, automatonData);

                    // all other possibilites go to the stack
                    for (uint i = 0; i < o; ++i) {
                        uint state_for_stack = state_from_slot(i, base_slot, n, automatonData);

                        if (state_for_stack != ID_FAIL) {
                            if (stack_size < MAX_STACK_SIZE) {
                                // push state to stack
                                stack[stack_size].startpos = startpos;
                                stack[stack_size].pos = pos + 1;
                                stack[stack_size].state = state_for_stack;
                                stack_size += 1;
                            } else {
                                flags[FLAG_STACK_FULL] = 1;
                            }
                        }
                    }
                }
            }
            // variant c) failed

            // check if stack is empty => goodbye
            if (stack_size == 0) {
                atomic_dec(&active_count);
            }
        }

        // continue counting
        iter_count += 1;
    }

    // write global error state
    if (iter_count >= MAX_ITER_COUNT) {
        flags[FLAG_ITER_MAX] = 1;
    }
}
