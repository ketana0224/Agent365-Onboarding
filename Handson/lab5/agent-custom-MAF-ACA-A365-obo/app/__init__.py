"""Contoso カスタマーサポート — OBO（ユーザー委任型）版。

lab3/lab4 の Agent ID 出口化版（agent-custom-MAF-ACA-A365-egress）を素体に、
ユーザー サインインで得たトークンを **fmi_path + jwt-bearer（OBO / Step 2b）** で交換し、
Agent ID として **ユーザーの委任コンテキスト**のまま Microsoft Graph を呼ぶ `/obo-chat`
エンドポイントを追加した版。
"""
