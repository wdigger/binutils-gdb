# A branch displacement is a count of words held in part of the
# instruction word itself, so one that does not fit overwrites the
# opcode's own bits and assembles as some other, perfectly valid
# instruction -- silently, and with a successful exit status, until
# this was diagnosed.
	.text
	bne	far		# 130 words: too far
	.space	260
far:	halt
	bne	far		# in range, backwards
	sob	r0,far		# in range
	.space	140
	sob	r0,far		# 74 words back: too far for a 6-bit field
	bne	odd+1		# lands on an odd address
odd:	halt
