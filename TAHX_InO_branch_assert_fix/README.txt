Correction des assertions de protocole dans les unités InO.

L3_INO_BRANCH_UNIT_rtl.vhd : CHECK_OPCODE devient synchrone.
L2_INO_MULDIV_UNIT_rtl.vhd : même correction préventive.

Raison : ISSUE_i est partagé entre les unités et les *_issue_valid_s sont dérivés
combinatoirement de issue_class. Un process(all) de vérification peut donc voir un
état transitoire pendant un delta-cycle qui n'est jamais échantillonné par le RTL.
