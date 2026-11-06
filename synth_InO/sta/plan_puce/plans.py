import os
import json, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plan_puce as P

import os
D = os.path.dirname(os.path.abspath(__file__))
liens = json.load(open(f"{D}/liens.json"))
B = {"ino_fetch": (1900, 2200), "ino_decode_predict": (900, 1100), "ino_decode_queue": (400, 1100),
     "stack_unit_16_8": (1500, 1500), "ino_exec_entier": (900, 1000), "ino_exec_arith": (1150, 1150),
     "ino_system": (1100, 1000), "ino_data_cache": (2275, 1062)}
def f(n): return open(n).read()
ORIG = {"ino_fetch": f(f"{D}/cfg/orig_ino_fetch.cfg"), "ino_decode_predict": f(f"{D}/cfg/orig_ino_decode_predict.cfg"),
        "ino_decode_queue": f(f"{D}/cfg/orig_decode_queue.cfg"), "stack_unit_16_8": f(f"{D}/cfg/orig_stack_unit_16_8.cfg"),
        "ino_exec_entier": f(f"{D}/cfg/orig_ino_exec_entier.cfg"), "ino_exec_arith": f(f"{D}/cfg/orig_ino_exec_arith.cfg"),
        "ino_system": f(f"{D}/cfg/orig_ino_system.cfg"), "ino_data_cache": f(f"{D}/cfg/orig_ino_data_cache.cfg")}
P67 = dict(ORIG)
P67.update({"ino_fetch": f(f"{D}/cfg/p68_ino_fetch.cfg"), "ino_decode_predict": f(f"{D}/cfg/p68_ino_decode_predict.cfg"),
            "stack_unit_16_8": f(f"{D}/cfg/p67_stack_unit_16_8.cfg"), "ino_exec_entier": f(f"{D}/cfg/p67_ino_exec_entier.cfg"),
            "ino_exec_arith": f(f"{D}/cfg/p67_ino_exec_arith.cfg"), "ino_system": f(f"{D}/cfg/p67_ino_system.cfg")})

# Groupes de broches (expressions de pin_order)
G = {
 "ent_stk": ["\\\\?issue_valid_i", "\\\\?issue_ready_o", "\\\\?issue_i\\..*", "\\\\?complete_o\\..*",
             "\\\\?frame_dsp_i.*", "\\\\?frame_rsp_i.*", "\\\\?disp_sel_o.*", "\\\\?disp_i.*",
             "\\\\?stack_maint_o\\..*", "\\\\?stack_maint_done_i"],
 "ent_ari": ["\\\\?arith_ready_i.*", "\\\\?arith_complete_.*"],
 "ent_mem": ["\\\\?mem_req_o\\..*", "\\\\?mem_ready_i", "\\\\?mem_rsp_i\\..*"],
 "ent_sys": ["\\\\?limits_i\\..*", "\\\\?sync_valid_i", "\\\\?sync_copile_i\\..*", "\\\\?copile_o\\..*"],
 "clk": ["\\\\?reset_i", "\\\\?clk_i"],
 "sys_stk": ["\\\\?issue_valid_i", "\\\\?issue_ready_o", "\\\\?issue_i\\..*", "\\\\?complete_o\\..*",
             "\\\\?frame_dsp_i.*", "\\\\?frame_rsp_i.*", "\\\\?disp_sel_o.*", "\\\\?disp_i.*",
             "\\\\?stack_maint_o\\..*", "\\\\?stack_maint_done_i", "\\\\?sync_valid_o", "\\\\?sync_dsp_o.*",
             "\\\\?sync_rsp_o.*", "\\\\?disp_we_o", "\\\\?disp_wsel_o.*", "\\\\?disp_wdata_o.*"],
 "sys_front": ["\\\\?fault_valid_i", "\\\\?fault_pc_i.*", "\\\\?fault_i\\..*", "\\\\?boundary_valid_i",
               "\\\\?boundary_pc_i.*", "\\\\?system_hold_o", "\\\\?redirect_valid_o", "\\\\?redirect_pc_o.*"],
 "sys_ent": ["\\\\?limits_o\\..*", "\\\\?copile_i\\..*", "\\\\?sync_copile_o\\..*"],
 "sys_mem": ["\\\\?mem_req_o\\..*", "\\\\?mem_ready_i", "\\\\?mem_rsp_i\\..*"],
 "sys_chip": ["\\\\?boot_block_i.*", "\\\\?irq_pending_i.*", "\\\\?irq_ack_o", "\\\\?irq_ack_code_o.*",
              "\\\\?halt_req_i", "\\\\?halted_o", "\\\\?halt_cause_o.*", "\\\\?exit_code_o.*", "\\\\?fpc_o.*",
              "\\\\?fcode_o.*", "\\\\?dr_o"],
 "ari_iss": ["\\\\?sync_valid_i", "\\\\?issue_valid_i", "\\\\?issue_class_i.*", "\\\\?issue_op_i.*",
             "\\\\?issue_a_i.*", "\\\\?issue_b_i.*", "\\\\?issue_c_i.*"],
 "ari_cpl": ["\\\\?ready_o.*", "\\\\?complete_valid_o", "\\\\?complete_result_valid_o",
             "\\\\?complete_result_o.*", "\\\\?complete_fault_o.*"],
 "fe_pred": ["\\\\?window_o.*", "\\\\?window_fault_o.*", "\\\\?window_count_o.*", "\\\\?window_pc_o.*",
             "\\\\?consume_i", "\\\\?consumed_bytes_i.*", "\\\\?decode_stop_i", "\\\\?predict_valid_i",
             "\\\\?predict_pc_i.*"],
 "fe_i": ["\\\\?i_req_o", "\\\\?i_ready_i", "\\\\?i_rvalid_i", "\\\\?i_fault_i", "\\\\?i_addr_o.*", "\\\\?i_rdata_i.*"],
 "fe_rec": ["\\\\?halt_i", "\\\\?recovery_valid_i", "\\\\?recovery_pc_i.*"],
 "pr_fe": ["\\\\?window_i.*", "\\\\?window_fault_i.*", "\\\\?window_count_i.*", "\\\\?window_pc_i.*",
           "\\\\?consume_o", "\\\\?consumed_bytes_o.*", "\\\\?stop_o", "\\\\?predict_valid_o", "\\\\?predict_pc_o.*"],
 "pr_out": ["\\\\?out_ready_i", "\\\\?out_valid_o", "\\\\?out_count_o.*", "\\\\?out_block_o.*"],
 "pr_rec": ["\\\\?recovery_i\\..*", "\\\\?retire_i\\..*"],
}
def cfg(**sides):
    out = ["@bit_major"]
    for s, items in sides.items():
        out.append("#" + s)
        for it in items:
            if isinstance(it, int):
                out.append(f"${it}")
            else:
                out += [x.replace("\\\\", "\\") for x in G[it]] if False else G[it]
    return "\n".join(out) + "\n"

def run(nom, plan, cfgs, soc, periph):
    print(f"== {nom}")
    return P.evaluer(plan, cfgs, B, {"SOC": soc, "PERIPH": periph}, liens)
